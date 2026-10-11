import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash,randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {relay} from './relay.mjs';

const r=relay();await r.start();const connections=new Map();let running=true;
const headers={authorization:`Bearer ${r.token}`,'content-type':'application/json'};
async function push(e){const res=await fetch('http://127.0.0.1:8080/push',{method:'POST',headers,body:JSON.stringify(e)});assert.equal(res.status,200);await res.text();}
// Ordinary TCP control receiver sends a SHA256 only after client half-close.
const receiver=net.createServer({allowHalfOpen:true},s=>{
  const hash=createHash('sha256');let count=0;
  s.on('data',d=>{hash.update(d);count+=d.length;s.pause();setTimeout(()=>s.resume(),2);});
  s.on('end',()=>s.end(JSON.stringify({count,sha256:hash.digest('hex')})));
});await new Promise(ok=>receiver.listen(53319,'127.0.0.1',ok));
const worker=(async()=>{
 while(running){
  const res=await fetch('http://127.0.0.1:8080/pull',{headers});assert.equal(res.status,200);const batch=await res.json();
  for(const e of batch){
   if(e.kind==='open'){
    const s=net.connect({host:'127.0.0.1',port:53319,allowHalfOpen:true});connections.set(e.id,s);
    (async()=>{for await(const d of s)await push({id:e.id,kind:'data',data:d.toString('base64')});await push({id:e.id,kind:'eof'});})().catch(err=>{if(running)throw err;});
   }else if(e.kind==='data'){const s=connections.get(e.id);await new Promise((ok,no)=>s.write(Buffer.from(e.data,'base64'),err=>err?no(err):ok()));}
   else if(e.kind==='eof')connections.get(e.id).end();
   else if(e.kind==='close'){connections.get(e.id)?.destroy();connections.delete(e.id);}
   else throw new Error(JSON.stringify(e));
  }
 }
})();
const results=[];
for(const size of [0,1,65537,16*1024*1024]){
 const data=randomBytes(size);const expected=createHash('sha256').update(data).digest('hex');
 const s=net.connect({host:'127.0.0.1',port:53318,allowHalfOpen:true});s.end(data);
 const chunks=[];for await(const d of s)chunks.push(d);const reply=JSON.parse(Buffer.concat(chunks));
 assert.equal(reply.count,size);assert.equal(reply.sha256,expected);results.push({bytes:size,byteExact:true,replyAfterHalfClose:true});
}
const pauses=[];
for(const seconds of [2,10,30]){
 const data=randomBytes(65537);const expected=createHash('sha256').update(data).digest('hex');
 const s=net.connect({host:'127.0.0.1',port:53318,allowHalfOpen:true});
 await new Promise((ok,no)=>{s.once('connect',ok);s.once('error',no);});
 s.write(data.subarray(0,1));
 const begin=process.hrtime.bigint();r.record('control-pause-start',undefined,{seconds});
 await new Promise(ok=>setTimeout(ok,seconds*1000));
 assert.equal(s.destroyed,false,'idle connection must stay open');
 const elapsedMs=Number(process.hrtime.bigint()-begin)/1e6;r.record('control-pause-end',undefined,{seconds,elapsedMs});
 s.end(data.subarray(1));
 const chunks=[];for await(const d of s)chunks.push(d);const reply=JSON.parse(Buffer.concat(chunks));
 assert.equal(reply.count,data.length);assert.equal(reply.sha256,expected);
 pauses.push({requestedSeconds:seconds,elapsedMs,aliveAfterPause:true,byteExact:true});
}
assert(r.status().paused>0,'large body must exercise relay backpressure');
assert(r.status().peak<2*1024*1024,'queued raw bytes must remain bounded');
writeFileSync('control-results.json',JSON.stringify({results,pauses,metrics:r.status()},null,2));
console.log(JSON.stringify({results,pauses,metrics:r.status()},null,2));
assert.equal(r.trace.filter(e=>e.origin==='device-eof').length,results.length+pauses.length);
const idle=net.connect({host:'127.0.0.1',port:53318,allowHalfOpen:true});
await new Promise((ok,no)=>{idle.once('connect',ok);idle.once('error',no);});
running=false;await r.stop();idle.destroy();for(const s of connections.values())s.destroy();await worker.catch(()=>{});await new Promise(ok=>receiver.close(ok));
assert(r.trace.some(e=>e.origin==='relay-stop-close'),'explicit infrastructure stop must be identifiable');
writeFileSync('relay-trace.json',JSON.stringify(r.trace,null,2));
