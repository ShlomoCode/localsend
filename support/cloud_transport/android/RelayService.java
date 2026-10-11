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
  private volatile boolean ready=false,destroying=false,firstPullSucceeded=false;
  private volatile String lifecycle="starting",lastFailure="";
  private volatile HttpURLConnection pullConnection;
  private volatile Thread pullThread;
  private volatile int ownedStartId;
  private String endpoint,token,transport="legacy",downlink="poll";
  private volatile String downlinkStreamId="",downlinkOutcome="not-opened";
  private volatile String downlinkNativeError="",retirementReason="",retirementOutcome="not-requested";
  private volatile long downlinkFirstReadMs,downlinkClosedMs;
  private static volatile String lastDownlinkObservation="{}";
  private long peerAbsoluteMs=15*60000;
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
    result.put("lastDownlinkObservation",new JSONObject(lastDownlinkObservation));
    if(service==null)return result.put("servicePresent",false).put("running",false).put("ready",false).put("lifecycle","stopped");
    ServerSocket bound=service.reverse?service.listener:service.control;
    boolean listenerBound=bound!=null&&bound.isBound()&&!bound.isClosed();
    result.put("servicePresent",true).put("instance",service.instance).put("running",service.running).put("ready",service.ready)
      .put("lifecycle",service.lifecycle).put("firstPullSucceeded",service.firstPullSucceeded).put("lastFailure",service.lastFailure)
      .put("listenerHost",listenerBound?"127.0.0.1":JSONObject.NULL).put("listenerPort",listenerBound?bound.getLocalPort():JSONObject.NULL)
      .put("transport",service.transport).put("downlink",service.downlink).put("downlinkStreamId",service.downlinkStreamId)
      .put("downlinkOutcome",service.downlinkOutcome).put("downlinkFirstReadMs",service.downlinkFirstReadMs).put("downlinkClosedMs",service.downlinkClosedMs)
      .put("downlinkNativeError",service.downlinkNativeError).put("retirementReason",service.retirementReason).put("retirementOutcome",service.retirementOutcome)
      .put("maxQueueBytes",QUEUE_LIMIT).put("readBufferBytes",READ_BUFFER).put("peerAbsoluteMs",service.peerAbsoluteMs);
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
    // Android advances the start ID even when this instance ignores a duplicate start.
    ownedStartId=id;
    if(running||destroying)return START_NOT_STICKY;
    NotificationManager nm=getSystemService(NotificationManager.class);
    nm.createNotificationChannel(new NotificationChannel("relay","Cloud transport",NotificationManager.IMPORTANCE_LOW));
    startForeground(1,new Notification.Builder(this,"relay").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("LocalSend cloud transport").setContentText("Diagnostic relay active").build());
    targetPort=intent.getBooleanExtra("control",false)?53319:53317;
    reverse=intent.getBooleanExtra("reverse",false);
    running=true;activeService=this;
    trace("service-start","-");
    pullThread=new Thread(()->{try{
      JSONObject config=new JSONObject(read(getAssets().open("config.json")));
      endpoint=config.getString("endpoint");token=config.getString("token");transport=intent.getStringExtra("transport");
      peerAbsoluteMs=intent.getLongExtra("peerAbsoluteMs",config.optLong("peerAbsoluteMs",15*60000));
      if(peerAbsoluteMs!=15*60000&&peerAbsoluteMs!=90*60000)throw new IOException("Invalid logical peer deadline");
      if(transport==null)transport=config.optString("transport","legacy");
      if(!transport.equals("legacy")&&!transport.equals("stream")&&!transport.equals("coalesced"))throw new IOException("Invalid transport mode");
      downlink=intent.getStringExtra("downlink");if(downlink==null)downlink=config.optString("downlink","poll");
      if(!downlink.equals("poll")&&!downlink.equals("persistent"))throw new IOException("Invalid downlink mode");
      trace("transport-mode:"+transport,"-");
      if(!running||activeService!=this)return;
      if(reverse)startReverse();else if(targetPort==53319)startControl();
      if(downlink.equals("persistent")){persistentDownlink();return;}
      while(running&&activeService==this){
        JSONArray batch=new JSONArray(request("GET","/pull",null));
        if(!running||activeService!=this)break;
        firstPullSucceeded=true;ready=true;lifecycle="ready";
        for(int i=0;i<batch.length()&&running&&activeService==this;i++)handle(batch.getJSONObject(i));
      }
    }catch(Exception e){failActiveService("pull-or-handler-failure",e);}},"relay-pull");pullThread.start();
    return START_NOT_STICKY;
  }
  private void persistentDownlink()throws Exception{
    HttpURLConnection c=(HttpURLConnection)new URL(endpoint+"/downlink").openConnection();
    c.setConnectTimeout(10000);c.setReadTimeout(0);c.setRequestMethod("GET");c.setRequestProperty("Authorization","Bearer "+token);
    pullConnection=c;downlinkOutcome="diagnostic-opening";InputStream input=null;
    try{
      if(!running||activeService!=this)throw new IOException("Owned stream cancelled before request");
      if(c.getResponseCode()!=200)throw new IOException("Persistent downlink response "+c.getResponseCode());
      downlinkStreamId=c.getHeaderField("x-relay-stream-id");
      if(downlinkStreamId==null||!downlinkStreamId.matches("[0-9]{1,20}"))throw new IOException("Missing physical downlink generation");
      trace("persistent-downlink-headers:"+downlinkStreamId,"-");
      // A zero read timeout permits only actual EOF/IOException to end this physical
      // stream. No quiet period, heartbeat or UI action is translated to peer error.
      input=new BufferedInputStream(c.getInputStream(),READ_BUFFER);
        ByteArrayOutputStream line=new ByteArrayOutputStream();int b;
        while(running&&activeService==this){
          b=input.read();
          if(b==-1){downlinkOutcome="native-http-eof";trace("persistent-downlink-native-eof:"+downlinkStreamId,"-");throw new EOFException("Persistent downlink physical response ended");}
          if(b=='\n'){
            JSONArray batch;
            try{batch=new JSONArray(line.toString("UTF-8"));}catch(JSONException invalid){downlinkOutcome="diagnostic-framing-failure";trace(downlinkOutcome,"-");throw invalid;}
            line.reset();if(batch.length()>8){downlinkOutcome="diagnostic-batch-bound";throw new IOException("Persistent batch exceeds bound");}
            if(!firstPullSucceeded){downlinkFirstReadMs=SystemClock.elapsedRealtime();firstPullSucceeded=true;ready=true;lifecycle="ready";downlinkOutcome="established-first-line";trace("persistent-downlink-first-read:"+downlinkStreamId,"-");}
            try{for(int i=0;i<batch.length()&&running&&activeService==this;i++)handle(batch.getJSONObject(i));}
            catch(Exception handler){downlinkOutcome="diagnostic-handler-failure";trace(downlinkOutcome+":"+handler.getClass().getSimpleName(),"-");throw handler;}
          }else{if(line.size()>=QUEUE_LIMIT){downlinkOutcome="diagnostic-line-bound";throw new IOException("Persistent line exceeds bound");}line.write(b);}
        }
      downlinkOutcome="diagnostic-owned-stop";downlinkClosedMs=SystemClock.elapsedRealtime();
    }catch(Exception error){
      downlinkClosedMs=SystemClock.elapsedRealtime();downlinkNativeError=error.getClass().getSimpleName();
      if(!running||destroying||activeService!=this){downlinkOutcome="diagnostic-owned-stop";trace(downlinkOutcome+":"+downlinkStreamId,"-");}
      else if(!downlinkOutcome.startsWith("diagnostic-")){downlinkOutcome="physical-read-failure:"+error.getClass().getSimpleName();trace(downlinkOutcome+":"+downlinkStreamId,"-");}
      throw error;
    }finally{
      // Retirement must precede closing the body. Otherwise a local parser or
      // handler failure could be mistaken for physical Wi-Fi loss at the server.
      if(downlinkOutcome.startsWith("diagnostic-")&&!downlinkOutcome.equals("diagnostic-owned-stop"))retireDownlink(downlinkOutcome);
      rememberDownlink();if(input!=null)try{input.close();}catch(Exception ignored){}
      if(pullConnection==c)pullConnection=null;c.disconnect();
    }
  }
  private void rememberDownlink(){
    try{lastDownlinkObservation=new JSONObject().put("instance",instance).put("streamId",downlinkStreamId).put("outcome",downlinkOutcome)
      .put("firstReadMs",downlinkFirstReadMs).put("closedMs",downlinkClosedMs).put("nativeErrorClass",downlinkNativeError)
      .put("retirementReason",retirementReason).put("retirementOutcome",retirementOutcome).toString();}catch(JSONException ignored){}
  }
  private void retireDownlink(String reason){
    retirementReason=reason;
    if(downlinkStreamId==null||downlinkStreamId.isEmpty()){retirementOutcome="no-established-generation";rememberDownlink();return;}
    HttpURLConnection retirement=null;
    try{
      retirement=(HttpURLConnection)new URL(endpoint+"/downlink-retire").openConnection();retirement.setConnectTimeout(3000);retirement.setReadTimeout(3000);retirement.setRequestMethod("POST");retirement.setDoOutput(true);
      retirement.setRequestProperty("Authorization","Bearer "+token);retirement.setRequestProperty("Content-Type","application/json");
      byte[] body=new JSONObject().put("streamId",downlinkStreamId).put("reason",reason).toString().getBytes("UTF-8");retirement.setFixedLengthStreamingMode(body.length);
      try(OutputStream output=retirement.getOutputStream()){output.write(body);}
      int code=retirement.getResponseCode();retirementOutcome=code==200?"acknowledged":"http"+code;trace("diagnostic-downlink-retire:"+reason+":"+retirementOutcome,"-");
    }catch(Exception failure){retirementOutcome="failed:"+failure.getClass().getSimpleName();trace("diagnostic-downlink-retire-report-failed:"+reason+":"+failure.getClass().getSimpleName(),"-");}
    finally{rememberDownlink();if(retirement!=null)retirement.disconnect();}
  }
  private void failActiveService(String origin,Exception error){
    if(!running||destroying||activeService!=this){trace("retired-worker-exit:"+origin,"-");return;}
    lastFailure=origin+":"+error.getClass().getSimpleName();ready=false;running=false;lifecycle="failed";
    trace(lastFailure,"-");Log.e("CloudTransport","Owned helper instance="+instance+" stopped: "+lastFailure);
    // A retired worker must never issue an unscoped stop against a later service start.
    stopSelfResult(ownedStartId);
  }
  private void startReverse()throws Exception{
    listener=new ServerSocket();listener.bind(new InetSocketAddress("127.0.0.1",53318));trace("reverse-listener-ready","-");
    new Thread(()->{int next=0;while(running){try{
      Socket s=listener.accept();String id="android-"+instance+"-"+(++next);sockets.put(id,s);trace("sender-accepted",id);
      new Thread(()->{try{push(new JSONObject().put("id",id).put("kind","open"));readSocket(id,s,"sender-read");}
        catch(Exception e){trace("reverse-open-failure:"+e.getClass().getSimpleName(),id);sockets.remove(id);try{s.close();}catch(Exception ignored){}}},"reverse-socket").start();
    }catch(Exception e){failActiveService("reverse-accept-failure",e);break;}}},"reverse-accept").start();
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
      if(now-metrics.startedMs>=peerAbsoluteMs||now-metrics.lastProgressMs>=PROGRESS_MS){
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
    boolean pull=method.equals("GET")&&path.equals("/pull");
    if(pull)pullConnection=c;
    try{
      if(pull&&(!running||activeService!=this))throw new IOException("Owned pull cancelled before request");
      if(body!=null){byte[] data=body.getBytes("UTF-8");c.setDoOutput(true);c.setFixedLengthStreamingMode(data.length);c.setRequestProperty("Content-Type","application/json");try(OutputStream out=c.getOutputStream()){out.write(data);}}
      if(c.getResponseCode()!=200)throw new IOException("Relay response "+c.getResponseCode());
      return read(c.getInputStream());
    }catch(Exception e){trace("http-failure:"+method+":"+path+":"+e.getClass().getSimpleName(),"-");throw e;}
    finally{if(pull&&pullConnection==c)pullConnection=null;c.disconnect();}
  }
  private static String read(InputStream in)throws Exception{try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=input.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");}}
  public void onDestroy(){
    trace("service-destroy","-");destroying=true;running=false;ready=false;lifecycle="stopping";
    try{if(listener!=null)listener.close();if(control!=null)control.close();}catch(Exception ignored){}
    // Cancellation/join run off the UI thread. Status remains 'stopping' until the owned pull worker is gone.
    new Thread(()->{
      if(downlink.equals("persistent")&&downlinkClosedMs==0)retireDownlink("service-cleanup");
      HttpURLConnection pull=pullConnection;if(pull!=null)pull.disconnect();
      for(String id:sockets.keySet())closeOwnedPeer(id,"service-close");sockets.clear();
      for(HttpURLConnection upload:uploads.values())upload.disconnect();uploads.clear();
      try{if(pullThread!=null)pullThread.join(10000);}catch(InterruptedException error){Thread.currentThread().interrupt();}
      if(pullThread!=null&&pullThread.isAlive()){lastFailure="Owned pull worker exceeded stop deadline";trace("service-stop-deadline","-");return;}
      // Initialization may have bound a listener after the first close; the worker is now retired.
      try{if(listener!=null)listener.close();if(control!=null)control.close();}catch(Exception ignored){}
      lifecycle="stopped";trace("service-stopped:"+instance,"-");if(activeService==this)activeService=null;
    },"relay-owned-cleanup").start();
    super.onDestroy();
  }
}
