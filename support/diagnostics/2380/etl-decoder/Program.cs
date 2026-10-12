// Decode retained external ETL on the authorized cloud worker; never start LocalSend here.
// Arguments: observer directory, exact expected LocalSend executable path.
using System.Text.Json;
using System.Security.Cryptography;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;

if (args.Length != 2) throw new ArgumentException("observer-directory expected-exe-path");
var dir = Path.GetFullPath(args[0]);
using var ready = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir,"ready.json")));
using var status = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir,"observer-status.json")));
var target = status.RootElement.GetProperty("targetPid").GetInt32();
var readyQpc = ready.RootElement.GetProperty("qpc").GetInt64();
var frequency = ready.RootElement.GetProperty("qpcFrequency").GetInt64();
var sessionName = ready.RootElement.GetProperty("session").GetString();
var imageGuid = new Guid("2cb15d1d-5fc1-11d2-abe1-00a0c911f518");
var processGuid = new Guid("3d6fa8d0-fe05-11d0-9dda-00c04fd7ba7c");
var rows = new List<object>(); var errors = new List<string>();
int processStarts=0, mainLoads=0, unknownRelevant=0, headers=0;
long? processStartQpc=null, processStopQpc=null;
void Require(bool valid,string why) { if(!valid) errors.Add(why); }
Require(status.RootElement.GetProperty("failure").ValueKind==JsonValueKind.Null,"capture failure");
Require(status.RootElement.GetProperty("hookError").ValueKind==JsonValueKind.Null,"hook failure");
Require(status.RootElement.GetProperty("unhooked").GetBoolean(),"unhook failure");
foreach(var key in new[]{"callbackErrors","etwStart","etwStop","eventsLost","logBuffersLost"})
  Require(status.RootElement.GetProperty(key).GetInt64()==0,"capture "+key+" nonzero");
var etl = Path.Combine(dir,"image-process.etl");
using var source = new ETWTraceEventSource(etl);
var kernel = new KernelTraceEventParser(source);
kernel.EventTraceHeader += data => {
  headers++;
  rows.Add(new {kind="trace-header",data.SessionName,data.PerfFreq,data.ReservedFlags,data.EventsLost,data.BuffersLost,data.PointerSize});
  Require(data.SessionName==sessionName,"ETL session identity differs");
  Require(data.PerfFreq==frequency,"QPC frequency differs");
  Require((data.ReservedFlags&3)==1,"ETL clock is not QPC");
  Require(data.EventsLost==0 && data.BuffersLost==0,"ETL header loss");
};
void ProcessEvent(string kind,ProcessTraceData data) {
  if(data.ProcessID!=target) return;
  Require(data.ProviderGuid==KernelTraceEventParser.ProviderGuid && data.TaskGuid==processGuid,"unexpected process provider/task");
  Require(data.Version<=5,"unknown process schema version "+data.Version);
  rows.Add(new {kind,pid=data.ProcessID,data.ParentID,data.ImageFileName,provider=data.ProviderGuid,task=data.TaskGuid,opcode=(int)data.Opcode,data.Version,data.PointerSize,qpc=data.TimeStampQPC,utc=data.TimeStamp.ToUniversalTime().ToString("O")});
  if(kind=="process-start") { processStarts++; processStartQpc=data.TimeStampQPC; Require(data.TimeStampQPC>=readyQpc,"target process predates hook readiness"); }
  if(kind=="process-stop") processStopQpc=data.TimeStampQPC;
}
kernel.ProcessStart += d=>ProcessEvent("process-start",d);
kernel.ProcessStop += d=>ProcessEvent("process-stop",d);
kernel.ProcessDCStart += d=>ProcessEvent("process-rundown-start",d);
kernel.ProcessDCStop += d=>ProcessEvent("process-rundown-stop",d);
void ImageEvent(string kind,ImageLoadTraceData data) {
  // Schema-qualified payload PID, not callback/header PID. v1/v2 offset follows pointer size.
  byte[] payload=data.EventData(); int pointer=data.PointerSize;
  if((pointer!=4 && pointer!=8) || data.Version<1 || data.Version>2 || payload.Length<2*pointer+4) {
    unknownRelevant++; errors.Add("unsupported/truncated image schema; cannot establish absence"); return;
  }
  int payloadPid=BitConverter.ToInt32(payload,2*pointer);
  if(payloadPid!=target) return;
  Require(data.ProviderGuid==KernelTraceEventParser.ProviderGuid && data.TaskGuid==imageGuid,"unexpected image provider/task");
  int nameOffset=data.Version==2 ? 32+3*pointer : 4+2*pointer;
  Require(payload.Length>=nameOffset+2,"target image missing filename payload");
  Require(!string.IsNullOrWhiteSpace(data.FileName),"target image path empty");
  Require(data.ProcessID==payloadPid,"parser/payload PID disagreement");
  rows.Add(new {kind,pid=payloadPid,parserPid=data.ProcessID,file=data.FileName,imageBase=data.ImageBase,imageSize=data.ImageSize,provider=data.ProviderGuid,task=data.TaskGuid,opcode=(int)data.Opcode,data.Version,data.PointerSize,qpc=data.TimeStampQPC,utc=data.TimeStamp.ToUniversalTime().ToString("O"),payload=Convert.ToBase64String(payload)});
  // DCStart/DCStop report already-mapped images and are NEVER counted as actual Load.
  if(kind=="image-load" && string.Equals(Path.GetFullPath(data.FileName),Path.GetFullPath(args[1]),StringComparison.OrdinalIgnoreCase)) mainLoads++;
}
kernel.ImageLoad += d=>ImageEvent("image-load",d); // opcode10 in this classic provider
kernel.ImageUnload += d=>ImageEvent("image-unload",d); // opcode2
kernel.ImageDCStart += d=>ImageEvent("image-rundown-start",d); // opcode3
kernel.ImageDCStop += d=>ImageEvent("image-rundown-stop",d); // opcode4
source.UnhandledEvents += data => {
  // Keep every unknown descriptor, even when PID is not target: payload PID may differ.
  bool relevant=data.TaskGuid==imageGuid || data.TaskGuid==processGuid || data.ProviderGuid==imageGuid || data.ProviderGuid==processGuid;
  if(relevant) unknownRelevant++;
  rows.Add(new {kind="unhandled",relevant,provider=data.ProviderGuid,task=data.TaskGuid,opcode=(int)data.Opcode,data.Version,data.PointerSize,headerPid=data.ProcessID,qpc=data.TimeStampQPC,payload=Convert.ToBase64String(data.EventData())});
};
bool processed=false;
try { processed=source.Process(); } catch(Exception ex) { errors.Add("decode exception: "+ex); }
Require(processed,"Process() incomplete");
Require(headers>0,"missing ETL header");
Require(source.EventsLost==0,"decoder EventsLost nonzero");
Require(processStarts==1,"expected exactly one real target process start");
Require(mainLoads>0,"missing real main executable load");
Require(unknownRelevant==0,"unknown process/image events prevent chronology or absence claims");
var options=new JsonSerializerOptions { WriteIndented=true };
File.WriteAllText(Path.Combine(dir,"decoded-events.json"),JsonSerializer.Serialize(rows,options));
File.WriteAllText(Path.Combine(dir,"decode-status.json"),JsonSerializer.Serialize(new {complete=errors.Count==0,errors,processed,eventsLost=source.EventsLost,processStarts,mainLoads,unknownRelevant,headers,processStartQpc,processStopQpc,targetPid=target,decoderPackage="Microsoft.Diagnostics.Tracing.TraceEvent/3.1.21",etlSha256=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(etl))),boundary="Win32/ETW only; no Flutter frame/surface evidence"},options));
return errors.Count==0 ? 0 : 2;
