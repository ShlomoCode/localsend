import http from 'node:http';
import net from 'node:net';
import {randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';

export function relay({httpPort=8080,tcpPort=53318,token=randomBytes(24).toString('hex')}={}) {
  const peers=new Map(); const events=[]; let waiter=null; let queued=0; let peak=0; let next=0;
  const metrics={opened:0,fromSender:0,fromDevice:0,paused:0};
  const trace=[];const started=process.hrtime.bigint();
  function record(origin,id,detail={}){trace.push({elapsedMs:Number(process.hrtime.bigint()-started)/1e6,origin,id,...detail});}
  function dequeue() {
    const batch=[];
    while(events.length && batch.length<8) {
      const e=events.shift(); batch.push(e); queued-=e.bytes||0;
    }
    if(queued<256*1024) for(const p of peers.values()) p.resume();
    return batch;
  }
  function wake() {if(waiter && events.length) {const w=waiter;waiter=null;clearTimeout(w.timer);w.res.end(JSON.stringify(dequeue()));}}
  function enqueue(e) {events.push(e);queued+=e.bytes||0;peak=Math.max(peak,queued);if(queued>512*1024){for(const p of peers.values())p.pause();metrics.paused++;}wake();}
  const tcp=net.createServer({allowHalfOpen:true},p=>{
    const id=String(++next); peers.set(id,p);metrics.opened++;
    record('sender-open',id);
    enqueue({id,kind:'open'});
    p.on('data',data=>{metrics.fromSender+=data.length;enqueue({id,kind:'data',bytes:data.length,data:data.toString('base64')});});
    p.on('end',()=>{record('sender-eof',id);enqueue({id,kind:'eof'});});
    p.on('error',e=>{record('sender-error',id,{code:e.code||'SOCKET_ERROR'});enqueue({id,kind:'error',error:e.code||'SOCKET_ERROR'});});
    p.on('close',()=>{record('sender-close',id);peers.delete(id);enqueue({id,kind:'close'});});
  });
  const server=http.createServer((req,res)=>{
    if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(401);res.end();return;}
    res.setHeader('content-type','application/json');
    if(req.method==='GET' && req.url==='/pull') {
      record("poll-open");if(waiter){record("poll-conflict");res.writeHead(409);res.end();return;}
      if(events.length){res.end(JSON.stringify(dequeue()));return;}
      const w={res,timer:setTimeout(()=>{record('poll-renewal');if(waiter===w)waiter=null;res.end('[]');},15000)};
      waiter=w;res.on('close',()=>{record("poll-close");if(waiter===w){clearTimeout(w.timer);waiter=null;}});return;
    }
    if(req.method==='GET' && req.url==='/status'){res.end(JSON.stringify({...metrics,queued,peak,peers:peers.size,pollPending:!!waiter}));return;}
    if(req.method==='POST' && req.url==='/push') {
      let raw=''; req.on('data',d=>{raw+=d;if(raw.length>256*1024)req.destroy();});
      req.on('end',()=>{
        try {
          const e=JSON.parse(raw);const p=peers.get(e.id);
          if(!p){res.writeHead(410);res.end('{}');return;}
          if(e.kind==='data'){const data=Buffer.from(e.data,'base64');metrics.fromDevice+=data.length;p.write(data,()=>res.end('{}'));}
          else if(e.kind==='eof'){record('device-eof',e.id);p.end();res.end('{}');}
          else if(e.kind==='error'){record('device-error',e.id,{source:e.origin||'unspecified'});p.destroy(new Error('Device socket failed'));res.end('{}');}
          else {res.writeHead(400);res.end('{}');}
        }catch{res.writeHead(400);res.end('{}');}
      });return;
    }
    res.writeHead(404);res.end('{}');
  });
  return {token,metrics,trace,record,status:()=>({...metrics,queued,peak,peers:peers.size,pollPending:!!waiter}),
    start:async()=>{await new Promise(r=>tcp.listen(tcpPort,'127.0.0.1',r));await new Promise(r=>server.listen(httpPort,'0.0.0.0',r));},
    stop:async()=>{record('relay-stop');if(waiter){clearTimeout(waiter.timer);waiter.res.end('[]');waiter=null;}for(const [id,p] of peers){record('relay-stop-close',id);p.destroy();}server.closeAllConnections();await Promise.all([new Promise(r=>server.close(r)),new Promise(r=>tcp.close(r))]);}};
}

if(process.argv[1]?.endsWith('/relay.mjs')) {
  const token=process.env.RELAY_TOKEN;if(!token)throw new Error('RELAY_TOKEN required');
  const r=relay({token});await r.start();
  console.log('relay ready: HTTP8080 / sender TCP53318');
  const timer=setInterval(()=>{writeFileSync('relay-status.json',JSON.stringify(r.status()));writeFileSync('relay-trace.json',JSON.stringify(r.trace));},3000);
  process.on('SIGTERM',async()=>{clearInterval(timer);await r.stop();process.exit();});
}
