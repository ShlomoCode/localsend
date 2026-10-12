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
  private String endpoint,token;
  private int targetPort;
  private ServerSocket control;
  private final ConcurrentHashMap<String,Socket> sockets=new ConcurrentHashMap<>();
  private void trace(String origin,String id){Log.i("CloudTransport","elapsedNs="+SystemClock.elapsedRealtimeNanos()+" origin="+origin+" peer="+id);}
  private void deliveryTrace(String stage,JSONObject event,long started,Exception error){
    try{
      JSONObject row=new JSONObject().put("stage",stage).put("peer",event.optString("id")).put("relayRequestId",event.optString("relayRequestId"))
        .put("sequence",event.optLong("sequence")).put("bytes",event.optInt("bytes")).put("kind",event.optString("kind"))
        .put("elapsedNs",SystemClock.elapsedRealtimeNanos()).put("durationMs",(SystemClock.elapsedRealtimeNanos()-started)/1000000);
      if(error!=null){
        JSONArray causes=new JSONArray(),frames=new JSONArray();Throwable cause=error;
        for(int i=0;cause!=null&&i<4;i++,cause=cause.getCause())causes.put(cause.getClass().getName());
        for(StackTraceElement frame:error.getStackTrace()){if(frames.length()>=8)break;frames.put(frame.getClassName()+"."+frame.getMethodName()+":"+frame.getLineNumber());}
        row.put("errorClasses",causes).put("stackFrames",frames);
      }
      Log.i("CloudTransport","delivery="+row.toString());
    }catch(Exception ignored){}
  }
  public IBinder onBind(Intent intent){return null;}
  public int onStartCommand(Intent intent,int flags,int id){
    if(running)return START_NOT_STICKY;
    NotificationManager nm=getSystemService(NotificationManager.class);
    nm.createNotificationChannel(new NotificationChannel("relay","Cloud transport",NotificationManager.IMPORTANCE_LOW));
    startForeground(1,new Notification.Builder(this,"relay").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("LocalSend cloud transport").setContentText("Diagnostic relay active").build());
    targetPort=intent.getBooleanExtra("control",false)?53319:53317;
    running=true;
    trace("service-start","-");
    new Thread(()->{try{
      JSONObject config=new JSONObject(read(getAssets().open("config.json")));
      endpoint=config.getString("endpoint");token=config.getString("token");
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
      new Thread(()->{String phase="target-read";JSONObject lastEvent=null;long sequence=0;try{
        byte[] buf=new byte[65536];int n;
        while((n=s.getInputStream().read(buf))!=-1){phase="http-push-data";
          JSONObject event=new JSONObject().put("id",id).put("kind","data").put("data",Base64.encodeToString(buf,0,n,Base64.NO_WRAP))
            .put("sequence",++sequence).put("relayRequestId",id+":"+sequence).put("bytes",n);
          lastEvent=event;deliveryTrace("target-read-positive",event,SystemClock.elapsedRealtimeNanos(),null);push(event);phase="target-read";
        }
        trace("target-read-eof",id);phase="http-push-eof";lastEvent=new JSONObject().put("id",id).put("kind","eof").put("sequence",++sequence).put("relayRequestId",id+":"+sequence).put("bytes",0);push(lastEvent);
      }catch(Exception ex){String origin=phase+":"+ex.getClass().getSimpleName();trace(origin,id);if(running)try{
        JSONObject error=new JSONObject().put("id",id).put("kind","error").put("origin",origin).put("sequence",++sequence).put("relayRequestId",id+":"+sequence).put("bytes",0);
        if(lastEvent!=null&&phase.startsWith("http-push"))error.put("failedRelayRequestId",lastEvent.optString("relayRequestId")).put("failedSequence",lastEvent.optLong("sequence")).put("failedBytes",lastEvent.optInt("bytes"));
        push(error);
      }catch(Exception ignored){trace("error-report-failed",id);}}},"relay-response").start();
    }else if(kind.equals("data")){sockets.get(id).getOutputStream().write(Base64.decode(e.getString("data"),Base64.NO_WRAP));}
    else if(kind.equals("eof")){trace("sender-eof-command",id);sockets.get(id).shutdownOutput();}
    else if(kind.equals("close")||kind.equals("error")){trace("relay-command:"+kind,id);Socket s=sockets.remove(id);if(s!=null)s.close();}
  }
  private void push(JSONObject e)throws Exception{
    long started=SystemClock.elapsedRealtimeNanos();
    try{request("POST","/push",e.toString(),e);}catch(Exception error){deliveryTrace("push-error",e,started,error);throw error;}
  }
  private String request(String method,String path,String body)throws Exception{
    return request(method,path,body,null);
  }
  private String request(String method,String path,String body,JSONObject event)throws Exception{
    long started=SystemClock.elapsedRealtimeNanos();String stage="connection-open";
    if(event!=null)deliveryTrace(stage,event,started,null);
    HttpURLConnection c=(HttpURLConnection)new URL(endpoint+path).openConnection();
    c.setConnectTimeout(10000);c.setReadTimeout(30000);c.setRequestMethod(method);c.setRequestProperty("Authorization","Bearer "+token);
    try{
      if(body!=null){byte[] data=body.getBytes("UTF-8");c.setDoOutput(true);c.setFixedLengthStreamingMode(data.length);c.setRequestProperty("Content-Type","application/json");
        stage="body-output-open";if(event!=null)deliveryTrace(stage,event,started,null);
        try(OutputStream out=c.getOutputStream()){stage="body-write";if(event!=null)deliveryTrace(stage,event,started,null);out.write(data);stage="body-written";if(event!=null)deliveryTrace(stage,event,started,null);}
        stage="body-output-closed";if(event!=null)deliveryTrace(stage,event,started,null);
      }
      stage="response-status";if(event!=null)deliveryTrace(stage,event,started,null);
      int status=c.getResponseCode();if(event!=null)deliveryTrace("response-status-"+status,event,started,null);
      if(status!=200){trace("http-status:"+method+":"+path+":"+status,"-");throw new IOException("Relay response "+status);}
      stage="response-body-read";String result=read(c.getInputStream());if(event!=null)deliveryTrace("post-complete",event,started,null);return result;
    }catch(Exception e){if(event!=null)deliveryTrace(stage+"-error",event,started,e);trace("http-failure:"+method+":"+path+":"+e.getClass().getSimpleName(),"-");throw e;}finally{c.disconnect();}
  }
  private static String read(InputStream in)throws Exception{try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=input.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");}}
  public void onDestroy(){trace("service-destroy","-");running=false;try{if(control!=null)control.close();}catch(Exception ignored){}for(String id:sockets.keySet())try{trace("service-close",id);sockets.get(id).close();}catch(Exception ignored){}sockets.clear();super.onDestroy();}
}
