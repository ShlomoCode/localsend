package org.localsend.cloudtransport;
import android.app.*;
import android.content.Intent;
import android.content.Context;
import android.content.ComponentName;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Base64;
import android.util.Log;
import org.json.*;
import java.net.*;
import java.io.*;
import java.util.concurrent.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;

public final class RelayService extends Service {
  private static final String processNonce=UUID.randomUUID().toString();
  private static final AtomicLong observationSequence=new AtomicLong();
  private static final Object activityLock=new Object();
  private static volatile boolean publicObservation=false;
  private static int startedActivities=0,resumedActivities=0;
  private static long activityVersion=0,activityElapsedNs=0;
  private static String lastActivityEvent="unobserved";
  private volatile boolean running=false;
  private String endpoint,token,serviceMode;
  private int targetPort;
  private ServerSocket control;
  private final ConcurrentHashMap<String,Socket> sockets=new ConcurrentHashMap<>();
  private void trace(String origin,String id){Log.i("CloudTransport","elapsedNs="+SystemClock.elapsedRealtimeNanos()+" origin="+origin+" peer="+id);}
  static void activityEvent(String event,int startedDelta,int resumedDelta){
    if(!publicObservation)return;
    synchronized(activityLock){
      startedActivities+=startedDelta;resumedActivities+=resumedDelta;
      lastActivityEvent=event;activityElapsedNs=SystemClock.elapsedRealtimeNanos();activityVersion++;
      Log.i("CloudTransport","own-activity nonce="+processNonce+" pid="+android.os.Process.myPid()+" uid="+android.os.Process.myUid()+" elapsedNs="+activityElapsedNs+" version="+activityVersion+" event="+event+" started="+startedActivities+" resumed="+resumedActivities);
    }
  }
  private static JSONObject activitySnapshot()throws Exception{
    synchronized(activityLock){
      if(startedActivities<0||resumedActivities<0||resumedActivities>startedActivities||activityVersion==0)throw new IllegalStateException("Inconsistent activity lifecycle");
      return new JSONObject().put("version",activityVersion).put("event",lastActivityEvent).put("elapsedNs",activityElapsedNs).put("started",startedActivities).put("resumed",resumedActivities);
    }
  }
  static JSONObject readConfig(Context context)throws Exception{
    JSONObject config=new JSONObject(read(context.getAssets().open("config.json")));
    String serviceMode=config.getString("serviceMode");
    if(!serviceMode.equals("foreground")&&!serviceMode.equals("ordinary"))throw new IllegalArgumentException("Invalid service mode");
    String observationMode=config.getString("observationMode");
    if(!observationMode.equals("native")&&!observationMode.equals("public-supplementary"))throw new IllegalArgumentException("Invalid observation mode");
    publicObservation=observationMode.equals("public-supplementary");
    return config;
  }
  public IBinder onBind(Intent intent){return null;}
  public int onStartCommand(Intent intent,int flags,int id){
    if(running)return START_NOT_STICKY;
    try{
      JSONObject config=readConfig(this);
      serviceMode=config.getString("serviceMode");
      endpoint=config.getString("endpoint");token=config.getString("token");
      targetPort=intent.getBooleanExtra("control",false)?53319:53317;
    }catch(Exception e){trace("config-failure:"+e.getClass().getSimpleName(),"-");Log.e("CloudTransport","Helper config failed: "+e.getClass().getSimpleName());stopSelf();return START_NOT_STICKY;}
    if(serviceMode.equals("foreground")){
      NotificationManager nm=getSystemService(NotificationManager.class);
      nm.createNotificationChannel(new NotificationChannel("relay","Cloud transport",NotificationManager.IMPORTANCE_LOW));
      startForeground(1,new Notification.Builder(this,"relay").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("LocalSend cloud transport").setContentText("Diagnostic relay active").build());
    }
    running=true;
    trace("service-start:mode="+serviceMode+":target="+targetPort,"-");
    new Thread(()->{try{
      if(targetPort==53319)startControl();
      while(running){JSONArray batch=new JSONArray(request("GET","/pull",null));for(int i=0;i<batch.length();i++)handle(batch.getJSONObject(i));}
    }catch(Exception e){trace("pull-or-handler-failure:"+e.getClass().getSimpleName(),"-");Log.e("CloudTransport","Relay stopped: "+e.getClass().getSimpleName());stopSelf();}},"relay-pull").start();
    return START_NOT_STICKY;
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
      Socket s=new Socket();s.connect(new InetSocketAddress("127.0.0.1",targetPort),5000);sockets.put(id,s);
      trace("target-connected",id);
      new Thread(()->{String phase="target-read";try{
        byte[] buf=new byte[65536];int n;
        while((n=s.getInputStream().read(buf))!=-1){phase="http-push-data";push(new JSONObject().put("id",id).put("kind","data").put("data",Base64.encodeToString(buf,0,n,Base64.NO_WRAP)));phase="target-read";}
        trace("target-read-eof",id);phase="http-push-eof";push(new JSONObject().put("id",id).put("kind","eof"));
      }catch(Exception ex){String origin=phase+":"+ex.getClass().getSimpleName();trace(origin,id);if(running)try{push(new JSONObject().put("id",id).put("kind","error").put("origin",origin));}catch(Exception ignored){trace("error-report-failed",id);}}},"relay-response").start();
    }else if(kind.equals("data")){sockets.get(id).getOutputStream().write(Base64.decode(e.getString("data"),Base64.NO_WRAP));}
    else if(kind.equals("eof")){trace("sender-eof-command",id);sockets.get(id).shutdownOutput();}
    else if(kind.equals("close")||kind.equals("error")){trace("relay-command:"+kind,id);Socket s=sockets.remove(id);if(s!=null)s.close();}
  }
  private void push(JSONObject e)throws Exception{request("POST","/push",e.toString());}
  // These are sampled public framework observations, not freezer-state or
  // continuous-health evidence. Only existing pull requests carry them.
  private JSONObject observation()throws Exception{
    long sampleStartNs=SystemClock.elapsedRealtimeNanos();
    JSONObject beforeActivity=activitySnapshot();
    int pid=android.os.Process.myPid(),uid=android.os.Process.myUid();
    ActivityManager manager=getSystemService(ActivityManager.class);
    ActivityManager.RunningAppProcessInfo process=new ActivityManager.RunningAppProcessInfo();
    ActivityManager.getMyMemoryState(process);
    if(process.pid!=pid||process.uid!=uid)throw new IllegalStateException("Own process identity mismatch");
    ComponentName expected=new ComponentName(this,RelayService.class);
    List<ActivityManager.RunningServiceInfo> services=manager.getRunningServices(64);
    ActivityManager.RunningServiceInfo own=null;
    int matches=0;
    if(services!=null)for(ActivityManager.RunningServiceInfo info:services){if(expected.equals(info.service)){own=info;matches++;}}
    if(matches!=1||own.pid!=pid||own.uid!=uid)throw new IllegalStateException("Own service identity missing or inconsistent");
    boolean foregroundFlag=(own.flags&ActivityManager.RunningServiceInfo.FLAG_FOREGROUND)!=0;
    boolean startedFlag=(own.flags&ActivityManager.RunningServiceInfo.FLAG_STARTED)!=0;
    if(own.foreground!=foregroundFlag||own.started!=startedFlag)throw new IllegalStateException("Own service flags inconsistent");
    JSONObject service=new JSONObject().put("component",own.service.flattenToString()).put("pid",own.pid).put("uid",own.uid).put("started",own.started).put("foreground",own.foreground).put("flags",own.flags).put("foregroundFlag",foregroundFlag).put("startedFlag",startedFlag).put("activeSinceMs",own.activeSince);
    JSONArray peers=new JSONArray();
    // Map membership can change while observed; report that limitation and
    // require the receiver to correlate peer events rather than assume atomicity.
    int peerCountStart=sockets.size();
    if(peerCountStart>32)throw new IllegalStateException("Peer observation limit exceeded");
    for(Map.Entry<String,Socket> entry:sockets.entrySet()){
      if(peers.length()>=32)throw new IllegalStateException("Peer observation limit exceeded");
      Socket socket=entry.getValue();
      peers.put(new JSONObject().put("id",entry.getKey()).put("closed",socket.isClosed()).put("connected",socket.isConnected()).put("inputShutdown",socket.isInputShutdown()).put("outputShutdown",socket.isOutputShutdown()).put("localAddress",socket.getLocalAddress().getHostAddress()).put("localPort",socket.getLocalPort()).put("remoteAddress",socket.getInetAddress().getHostAddress()).put("remotePort",socket.getPort()));
    }
    JSONObject afterActivity=activitySnapshot();
    boolean activityStable=beforeActivity.getLong("version")==afterActivity.getLong("version");
    int peerCountEnd=sockets.size();
    if(peerCountEnd>32)throw new IllegalStateException("Peer observation limit exceeded");
    long sampleEndNs=SystemClock.elapsedRealtimeNanos();
    return new JSONObject().put("schema",1).put("processNonce",processNonce).put("sequence",observationSequence.incrementAndGet()).put("sampleStartNs",sampleStartNs).put("sampleEndNs",sampleEndNs).put("pid",pid).put("uid",uid).put("memoryState",new JSONObject().put("pid",process.pid).put("uid",process.uid)).put("importance",process.importance).put("serviceMode",serviceMode).put("activityBefore",beforeActivity).put("activity",afterActivity).put("activityStable",activityStable).put("serviceMatches",matches).put("service",service).put("peerCountStart",peerCountStart).put("peerCountEnd",peerCountEnd).put("peers",peers).put("peerSnapshotAtomic",false);
  }
  private String request(String method,String path,String body)throws Exception{
    HttpURLConnection c=(HttpURLConnection)new URL(endpoint+path).openConnection();
    c.setConnectTimeout(10000);c.setReadTimeout(30000);c.setRequestMethod(method);c.setRequestProperty("Authorization","Bearer "+token);
    try{
      if(publicObservation&&method.equals("GET")&&path.equals("/pull")){
        JSONObject sample=observation();
        sample.put("emittedElapsedNs",SystemClock.elapsedRealtimeNanos());
        byte[] observationBytes=sample.toString().getBytes("UTF-8");
        if(observationBytes.length>8192)throw new IllegalStateException("Observation payload limit exceeded");
        c.setRequestProperty("X-CloudTransport-Observation",Base64.encodeToString(observationBytes,Base64.NO_WRAP));
        Log.i("CloudTransport","own-observation "+sample.toString());
      }
      if(body!=null){byte[] data=body.getBytes("UTF-8");c.setDoOutput(true);c.setFixedLengthStreamingMode(data.length);c.setRequestProperty("Content-Type","application/json");try(OutputStream out=c.getOutputStream()){out.write(data);}}
      int status=c.getResponseCode();if(status!=200){trace("http-status:"+method+":"+path+":"+status,"-");throw new IOException("Relay response "+status);}
      return read(c.getInputStream());
    }catch(Exception e){trace("http-failure:"+method+":"+path+":"+e.getClass().getSimpleName(),"-");throw e;}finally{c.disconnect();}
  }
  private static String read(InputStream in)throws Exception{try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=input.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");}}
  public void onDestroy(){trace("service-destroy","-");running=false;try{if(control!=null)control.close();}catch(Exception ignored){}for(String id:sockets.keySet())try{trace("service-close",id);sockets.get(id).close();}catch(Exception ignored){}sockets.clear();super.onDestroy();}
}
