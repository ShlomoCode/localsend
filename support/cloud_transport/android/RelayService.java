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
  private String request(String method,String path,String body)throws Exception{
    HttpURLConnection c=(HttpURLConnection)new URL(endpoint+path).openConnection();
    c.setConnectTimeout(10000);c.setReadTimeout(30000);c.setRequestMethod(method);c.setRequestProperty("Authorization","Bearer "+token);
    try{
      if(body!=null){byte[] data=body.getBytes("UTF-8");c.setDoOutput(true);c.setFixedLengthStreamingMode(data.length);c.setRequestProperty("Content-Type","application/json");try(OutputStream out=c.getOutputStream()){out.write(data);}}
      int status=c.getResponseCode();if(status!=200){trace("http-status:"+method+":"+path+":"+status,"-");throw new IOException("Relay response "+status);}
      return read(c.getInputStream());
    }catch(Exception e){trace("http-failure:"+method+":"+path+":"+e.getClass().getSimpleName(),"-");throw e;}finally{c.disconnect();}
  }
  private static String read(InputStream in)throws Exception{try(InputStream input=in;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=input.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");}}
  public void onDestroy(){trace("service-destroy","-");running=false;try{if(control!=null)control.close();}catch(Exception ignored){}for(String id:sockets.keySet())try{trace("service-close",id);sockets.get(id).close();}catch(Exception ignored){}sockets.clear();super.onDestroy();}
}
