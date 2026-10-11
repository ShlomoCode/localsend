package org.localsend.cloudtransport;
import android.app.*;
import android.content.Intent;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Base64;
import android.util.Log;
import org.json.*;
import java.net.*;
import java.io.*;
import java.util.concurrent.*;
import java.security.MessageDigest;

public final class RelayService extends Service {
  private volatile boolean running=false;
  private String endpoint,token,transport="legacy";
  private final String instance=java.util.UUID.randomUUID().toString().replace("-","").substring(0,8);
  private final ConcurrentHashMap<String,HttpURLConnection> uploads=new ConcurrentHashMap<>();
  private final ConcurrentHashMap<String,UploadMetrics> uploadMetrics=new ConcurrentHashMap<>();
  private static volatile RelayService activeService;
  private static final int QUEUE_LIMIT=1024*1024,READ_BUFFER=65536;
  private static final long PROGRESS_MS=90000,ABSOLUTE_MS=15*60000,COALESCE_MS=20;
  private static final class UploadMetrics {
    volatile long bytes,chunks,requests,startedMs,lastProgressMs,finishedMs;
    volatile int peakQueuedBytes;
    volatile String phase="opening",error="";
  }
  public static JSONObject transportStatus() throws JSONException {
    RelayService service=activeService;JSONObject result=new JSONObject();
    if(service==null)return result.put("running",false);
    result.put("running",service.running).put("transport",service.transport).put("maxQueueBytes",QUEUE_LIMIT).put("readBufferBytes",READ_BUFFER);
    JSONObject peers=new JSONObject();
    for(String id:service.uploadMetrics.keySet()){
      UploadMetrics m=service.uploadMetrics.get(id);
      peers.put(id,new JSONObject().put("bytes",m.bytes).put("chunks",m.chunks).put("requests",m.requests).put("peakQueuedBytes",m.peakQueuedBytes)
        .put("startedMs",m.startedMs).put("lastProgressMs",m.lastProgressMs).put("finishedMs",m.finishedMs).put("phase",m.phase).put("error",m.error));
    }
    return result.put("peers",peers);
  }
  private int targetPort;
  private boolean reverse;
  private ServerSocket listener;
  private ServerSocket control;
  private final ConcurrentHashMap<String,Socket> sockets=new ConcurrentHashMap<>();
  private void trace(String origin,String id){Log.i("CloudTransport","elapsedNs="+SystemClock.elapsedRealtimeNanos()+" origin="+origin+" peer="+id);}
  public IBinder onBind(Intent intent){return null;}
  public int onStartCommand(Intent intent,int flags,int id){
    if(running)return START_NOT_STICKY;
    NotificationManager nm=getSystemService(NotificationManager.class);
    nm.createNotificationChannel(new NotificationChannel("relay","Cloud transport",NotificationManager.IMPORTANCE_LOW));
    startForeground(1,new Notification.Builder(this,"relay").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("LocalSend cloud transport").setContentText("Diagnostic relay active").build());
    targetPort=intent.getBooleanExtra("control",false)?53319:53317;
    reverse=intent.getBooleanExtra("reverse",false);
    running=true;activeService=this;
    trace("service-start","-");
    new Thread(()->{try{
      JSONObject config=new JSONObject(read(getAssets().open("config.json")));
      endpoint=config.getString("endpoint");token=config.getString("token");transport=intent.getStringExtra("transport");
      if(transport==null)transport=config.optString("transport","legacy");
      if(!transport.equals("legacy")&&!transport.equals("stream")&&!transport.equals("coalesced"))throw new IOException("Invalid transport mode");
      trace("transport-mode:"+transport,"-");
      if(reverse)startReverse();else if(targetPort==53319)startControl();
      while(running){JSONArray batch=new JSONArray(request("GET","/pull",null));for(int i=0;i<batch.length();i++)handle(batch.getJSONObject(i));}
    }catch(Exception e){trace("pull-or-handler-failure:"+e.getClass().getSimpleName(),"-");Log.e("CloudTransport","Relay stopped: "+e.getClass().getSimpleName());stopSelf();}},"relay-pull").start();
    return START_NOT_STICKY;
  }
  private void startReverse()throws Exception{
    listener=new ServerSocket();listener.bind(new InetSocketAddress("127.0.0.1",53318));trace("reverse-listener-ready","-");
    new Thread(()->{int next=0;while(running){try{
      Socket s=listener.accept();String id="android-"+instance+"-"+(++next);sockets.put(id,s);trace("sender-accepted",id);
      new Thread(()->{try{push(new JSONObject().put("id",id).put("kind","open"));readSocket(id,s,"sender-read");}
        catch(Exception e){trace("reverse-open-failure:"+e.getClass().getSimpleName(),id);sockets.remove(id);try{s.close();}catch(Exception ignored){}}},"reverse-socket").start();
    }catch(Exception e){if(running){trace("reverse-accept-failure:"+e.getClass().getSimpleName(),"-");stopSelf();}break;}}},"reverse-accept").start();
  }
  private void readSocket(String id,Socket s,String readOrigin){
    if(!transport.equals("legacy")){readBinarySocket(id,s,readOrigin);return;}
    String phase=readOrigin;try{
      byte[] buf=new byte[65536];int n;
      while((n=s.getInputStream().read(buf))!=-1){phase="http-push-data";push(new JSONObject().put("id",id).put("kind","data").put("data",Base64.encodeToString(buf,0,n,Base64.NO_WRAP)));phase=readOrigin;}
      trace(readOrigin+"-eof",id);phase="http-push-eof";push(new JSONObject().put("id",id).put("kind","eof"));
    }catch(Exception ex){String origin=phase+":"+ex.getClass().getSimpleName();trace(origin,id);if(running)try{push(new JSONObject().put("id",id).put("kind","error").put("origin",origin));}catch(Exception ignored){trace("error-report-failed",id);}}
  }
  private HttpURLConnection uploadConnection(String id,String route,UploadMetrics metrics,int length)throws Exception{
    HttpURLConnection c=(HttpURLConnection)new URL(endpoint+route+id).openConnection();
    c.setConnectTimeout(10000);c.setReadTimeout((int)PROGRESS_MS);c.setRequestMethod("POST");c.setDoOutput(true);
    c.setRequestProperty("Authorization","Bearer "+token);c.setRequestProperty("Content-Type","application/octet-stream");
    if(length<0)c.setChunkedStreamingMode(READ_BUFFER);else c.setFixedLengthStreamingMode(length);
    if(uploads.putIfAbsent(id,c)!=null){c.disconnect();throw new IOException("Duplicate upload for owned peer");}
    metrics.requests++;return c;
  }
  private void binaryBatch(String id,byte[] bytes,int count,UploadMetrics metrics)throws Exception{
    HttpURLConnection c=uploadConnection(id,"/binary/",metrics,count);
    try{
      metrics.phase="binary-batch-write";
      try(OutputStream out=c.getOutputStream()){out.write(bytes,0,count);out.flush();}
      metrics.phase="binary-batch-response";
      if(c.getResponseCode()!=200)throw new IOException("Binary relay response "+c.getResponseCode());
      read(c.getInputStream());
    }finally{uploads.remove(id,c);c.disconnect();}
  }
  private void closeOwnedPeer(String id,String origin){
    trace(origin,id);Socket socket=sockets.remove(id);if(socket!=null)try{socket.close();}catch(Exception ignored){}
    HttpURLConnection upload=uploads.remove(id);if(upload!=null)upload.disconnect();
  }
  private void readBinarySocket(String id,Socket s,String readOrigin){
    UploadMetrics metrics=new UploadMetrics();metrics.startedMs=metrics.lastProgressMs=SystemClock.elapsedRealtime();uploadMetrics.put(id,metrics);
    ScheduledExecutorService watchdog=Executors.newSingleThreadScheduledExecutor();
    watchdog.scheduleAtFixedRate(()->{
      long now=SystemClock.elapsedRealtime();
      if(now-metrics.startedMs>=ABSOLUTE_MS||now-metrics.lastProgressMs>=PROGRESS_MS){
        metrics.error="Upload deadline at "+metrics.phase;closeOwnedPeer(id,"upload-watchdog");
      }
    },1,1,TimeUnit.SECONDS);
    try{
      byte[] buffer=new byte[READ_BUFFER];int n;
      if(transport.equals("stream")){
        s.setSoTimeout((int)PROGRESS_MS);
        HttpURLConnection c=uploadConnection(id,"/upload/",metrics,-1);
        try{
          try(OutputStream out=c.getOutputStream()){
            while(true){
              metrics.phase=readOrigin;n=s.getInputStream().read(buffer);if(n==-1)break;
              metrics.bytes+=n;metrics.chunks++;metrics.peakQueuedBytes=Math.max(metrics.peakQueuedBytes,n);metrics.lastProgressMs=SystemClock.elapsedRealtime();
              metrics.phase="stream-write";out.write(buffer,0,n);out.flush();
            }
            // Only native socket EOF completes this HTTP request; never a quiet period or an app UI result.
            metrics.phase="stream-eof";trace(readOrigin+"-eof",id);
          }
          metrics.phase="stream-response-after-eof";
          if(c.getResponseCode()!=200)throw new IOException("Stream relay response "+c.getResponseCode());read(c.getInputStream());
        }finally{uploads.remove(id,c);c.disconnect();}
      }else{
        byte[] pending=new byte[QUEUE_LIMIT];int count=0;s.setSoTimeout((int)COALESCE_MS);long batchStarted=0;
        while(true){
          metrics.phase=readOrigin;
          try{n=s.getInputStream().read(buffer,0,Math.min(buffer.length,QUEUE_LIMIT-count));}
          catch(SocketTimeoutException idle){n=0;}
          if(n>0){
            if(count==0)batchStarted=SystemClock.elapsedRealtime();System.arraycopy(buffer,0,pending,count,n);count+=n;
            metrics.bytes+=n;metrics.chunks++;metrics.peakQueuedBytes=Math.max(metrics.peakQueuedBytes,count);metrics.lastProgressMs=SystemClock.elapsedRealtime();
          }
          if(count>0&&(count==QUEUE_LIMIT||n==-1||SystemClock.elapsedRealtime()-batchStarted>=COALESCE_MS)){
            binaryBatch(id,pending,count,metrics);count=0;
          }
          if(n==-1){metrics.phase="binary-native-eof";trace(readOrigin+"-eof",id);push(new JSONObject().put("id",id).put("kind","eof"));break;}
        }
      }
      metrics.phase="finished";metrics.finishedMs=SystemClock.elapsedRealtime();
    }catch(Exception error){
      metrics.error=metrics.phase+":"+error.getClass().getSimpleName();trace(metrics.error,id);
      if(running)try{push(new JSONObject().put("id",id).put("kind","error").put("origin",metrics.error));}catch(Exception ignored){trace("error-report-failed",id);}
      closeOwnedPeer(id,"owned-upload-failure");
    }finally{watchdog.shutdownNow();}
  }
  private void startControl()throws Exception{
    control=new ServerSocket();control.bind(new InetSocketAddress("127.0.0.1",53319));
    new Thread(()->{while(running){try{
      Socket s=control.accept();new Thread(()->{try{
        MessageDigest hash=MessageDigest.getInstance("SHA-256");long count=0;byte[] buf=new byte[65536];int n;
        while((n=s.getInputStream().read(buf))!=-1){hash.update(buf,0,n);count+=n;Thread.sleep(2);}
        StringBuilder hex=new StringBuilder();for(byte b:hash.digest())hex.append(String.format("%02x",b&255));
        String reply=new JSONObject().put("count",count).put("sha256",hex.toString()).toString();
        s.getOutputStream().write(reply.getBytes("UTF-8"));s.shutdownOutput();s.close();
      }catch(Exception e){Log.e("CloudTransport","Control socket failed");}},"control-socket").start();
    }catch(Exception e){if(running)Log.e("CloudTransport","Control listener failed");break;}}},"control-accept").start();
  }
  private void handle(JSONObject e)throws Exception{
    String id=e.getString("id"),kind=e.getString("kind");
    if(kind.equals("open")){
      if(reverse)throw new IOException("Unexpected reverse open command");
      Socket s=new Socket();s.connect(new InetSocketAddress("127.0.0.1",targetPort),5000);sockets.put(id,s);
      trace("target-connected",id);
      new Thread(()->readSocket(id,s,"target-read"),"relay-response").start();
    }else if(kind.equals("data")){
      Socket socket=sockets.get(id);if(socket==null||socket.isClosed()){trace("data-ignored:closed-peer",id);return;}
      try{socket.getOutputStream().write(Base64.decode(e.getString("data"),Base64.NO_WRAP));}
      catch(IOException error){closeOwnedPeer(id,"owned-pull-write-failure:"+error.getClass().getSimpleName());}
    }
    else if(kind.equals("eof")){
      trace("sender-eof-command",id);Socket s=sockets.get(id);
      if(s==null||s.isClosed()||s.isOutputShutdown()){
        trace("sender-eof-ignored:"+(s==null?"missing":s.isClosed()?"closed":"output-shutdown"),id);
        Log.i("CloudTransport","peer="+id+" eofIgnored active="+new java.util.TreeSet<>(sockets.keySet()));return;
      }
      try{s.shutdownOutput();}
      catch(IOException ex){
        // A completed HTTP peer must not stop the pull loop and close a separate live upload.
        trace("sender-eof-shutdown-failed:"+ex.getClass().getSimpleName(),id);
        String activeBefore=new java.util.TreeSet<>(sockets.keySet()).toString();
        sockets.remove(id,s);
        try{s.close();}catch(IOException closeError){trace("sender-eof-close-failed:"+closeError.getClass().getSimpleName(),id);}
        String message=String.valueOf(ex.getMessage()).replace('\n',' ').replace('\r',' ');
        if(token!=null&&!token.isEmpty())message=message.replace(token,"[redacted]");
        if(endpoint!=null&&!endpoint.isEmpty())message=message.replace(endpoint,"[redacted endpoint]");
        message=message.replaceAll("https?://\\S+","[redacted URL]");
        if(message.length()>240)message=message.substring(0,240);
        Log.i("CloudTransport","peer="+id+" eofException="+ex.getClass().getSimpleName()+" message="+message
          +" activeBefore="+activeBefore+" activeAfter="+new java.util.TreeSet<>(sockets.keySet()));
      }
    }
    else if(kind.equals("close")||kind.equals("error")){closeOwnedPeer(id,"relay-command:"+kind);}
  }
  private void push(JSONObject e)throws Exception{request("POST","/push",e.toString());}
  private String request(String method,String path,String body)throws Exception{
    HttpURLConnection c=(HttpURLConnection)new URL(endpoint+path).openConnection();
    c.setConnectTimeout(10000);c.setReadTimeout(30000);c.setRequestMethod(method);c.setRequestProperty("Authorization","Bearer "+token);
    try{
      if(body!=null){byte[] data=body.getBytes("UTF-8");c.setDoOutput(true);c.setFixedLengthStreamingMode(data.length);c.setRequestProperty("Content-Type","application/json");try(OutputStream out=c.getOutputStream()){out.write(data);}}
      if(c.getResponseCode()!=200)throw new IOException("Relay response "+c.getResponseCode());
      return read(c.getInputStream());
    }catch(Exception e){trace("http-failure:"+method+":"+path+":"+e.getClass().getSimpleName(),"-");throw e;}finally{c.disconnect();}
  }
  private static String read(InputStream in)throws Exception{try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=input.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");}}
  public void onDestroy(){trace("service-destroy","-");running=false;try{if(listener!=null)listener.close();if(control!=null)control.close();}catch(Exception ignored){}for(String id:sockets.keySet())closeOwnedPeer(id,"service-close");sockets.clear();for(HttpURLConnection upload:uploads.values())upload.disconnect();uploads.clear();if(activeService==this)activeService=null;super.onDestroy();}
}
