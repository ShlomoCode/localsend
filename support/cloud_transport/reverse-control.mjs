import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash,randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {relay} from './relay.mjs';

// Simulated Android sender uses a local listener, preserving bytes and half-close.
const receiver=net.createServer({allowHalfOpen:true},s=>{
 const hash=createHash('sha256');let bytes=0;
 s.on('data',data=>{bytes+=data.length;hash.update(data);s.pause();setTimeout(()=>s.resume(),2);});
 s.on('end',()=>s.end(JSON.stringify({bytes,sha256:hash.digest('hex')})));
});await new Promise(ok=>receiver.listen(53319,'127.0.0.1',ok));
const r=relay({reverseTargetPort:53319});await r.start();
const headers={authorization:`Bearer ${r.token}`,'content-type':'application/json'};
async function push(event){const res=await fetch('http://127.0.0.1:8080/push',{method:'POST',headers,body:JSON.stringify(event)});assert.equal(res.status,200);await res.text();}
const sockets=new Map();const readers=[];let next=0,running=true;
const listener=net.createServer({allowHalfOpen:true},s=>{
 const id='android-'+(++next);sockets.set(id,s);
 readers.push((async()=>{
  await push({id,kind:'open'});
  for await(const data of s)await push({id,kind:'data',data:data.toString('base64')});
  await push({id,kind:'eof'});
 })());
});await new Promise(ok=>listener.listen(53320,'127.0.0.1',ok));
const worker=(async()=>{
 while(running){
  const res=await fetch('http://127.0.0.1:8080/pull',{headers});assert.equal(res.status,200);
  for(const event of await res.json()){
   const s=sockets.get(event.id);
   if(event.kind==='data')await new Promise((ok,no)=>s.write(Buffer.from(event.data,'base64'),err=>err?no(err):ok()));
   else if(event.kind==='eof')s.end();
   else if(event.kind==='close'){s?.destroy();sockets.delete(event.id);}
   else throw new Error('Reverse target error: '+event.error);
  }
 }
})();
const results=[];
for(const [bytes,pauseSeconds] of [[0,0],[1,0],[65537,2],[65537,10],[65537,30],[32*1024*1024,0]]){
 const s=net.connect({host:'127.0.0.1',port:53320,allowHalfOpen:true});
 const chunks=[];s.on('data',chunk=>chunks.push(chunk));
 await new Promise((ok,no)=>{s.once('connect',ok);s.once('error',no);});
 const done=new Promise((ok,no)=>{s.once('end',ok);s.once('error',no);});
 const hash=createHash('sha256');let sent=0,durationMs=0;
 if(bytes){const byte=randomBytes(1);hash.update(byte);s.write(byte);sent=1;}
 if(pauseSeconds){
  const start=process.hrtime.bigint();r.record('reverse-pause-start',undefined,{seconds:pauseSeconds});
  await new Promise(ok=>setTimeout(ok,pauseSeconds*1000));durationMs=Number(process.hrtime.bigint()-start)/1e6;
  assert.equal(s.destroyed,false);r.record('reverse-pause-end',undefined,{seconds:pauseSeconds,durationMs});
 }
 while(sent<bytes){const chunk=randomBytes(Math.min(65536,bytes-sent));hash.update(chunk);sent+=chunk.length;if(!s.write(chunk))await new Promise(ok=>s.once('drain',ok));}
 s.end();await done;const reply=JSON.parse(Buffer.concat(chunks));
 assert.equal(reply.bytes,bytes);assert.equal(reply.sha256,hash.digest('hex'));
 results.push({bytes,pauseSeconds,durationMs,aliveAfterPause:true,byteExact:true,replyAfterHalfClose:true});
}
assert(r.status().peak<2*1024*1024);
running=false;await r.stop();for(const s of sockets.values())s.destroy();
await worker.catch(()=>{});await Promise.all(readers);await new Promise(ok=>listener.close(ok));await new Promise(ok=>receiver.close(ok));
writeFileSync('reverse-control-results.json',JSON.stringify({results,metrics:r.status(),maxGeneratedChunk:65536},null,2));
writeFileSync('reverse-relay-trace.json',JSON.stringify(r.trace,null,2));
console.log(JSON.stringify({results,metrics:r.status(),maxGeneratedChunk:65536},null,2));
