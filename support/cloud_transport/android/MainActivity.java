package org.localsend.cloudtransport;
import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.content.Intent;
import android.widget.*;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.io.OutputStream;
import java.util.concurrent.atomic.AtomicReference;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MainActivity extends Activity {
  private boolean reverseControlBusy;
  private boolean transportControlBusy;
  private final Handler serviceObserver=new Handler(Looper.getMainLooper());
  private int serviceObservationGeneration;
  private boolean serviceObservationPending;
  private Button[] serviceModeButtons;
  private static void showStatus(TextView text,String value) {text.setText(value);text.setContentDescription(value);}
  private void observeService(TextView text,boolean starting,Integer expectedPort,String expectedTransport,String readyText) {
    final int generation=++serviceObservationGeneration;
    final long started=android.os.SystemClock.elapsedRealtime();
    serviceObservationPending=true;
    for(Button button:serviceModeButtons)button.setEnabled(false);
    Runnable poll=new Runnable() {
      public void run() {
        if(generation!=serviceObservationGeneration||isFinishing()||isDestroyed())return;
        JSONObject status;
        try {status=RelayService.transportStatus();}
        catch(Exception error) {status=new JSONObject();try{status.put("statusReadErrorType",error.getClass().getSimpleName());}catch(Exception ignored){}}
        long elapsed=android.os.SystemClock.elapsedRealtime()-started;
        boolean observed=status.opt("servicePresent") instanceof Boolean&&status.opt("running") instanceof Boolean&&status.opt("ready") instanceof Boolean;
        boolean complete=observed&&(starting
          ?status.optBoolean("ready")&&status.optBoolean("running")&&status.optBoolean("servicePresent")&&status.optBoolean("firstPullSucceeded")
            &&(expectedPort==null||status.optInt("listenerPort",-1)==expectedPort&&"127.0.0.1".equals(status.optString("listenerHost")))
            &&(expectedTransport==null||expectedTransport.equals(status.optString("transport")))
          :!status.optBoolean("servicePresent")&&!status.optBoolean("running")&&!status.optBoolean("ready"));
        boolean timeout=!complete&&elapsed>=30000;
        try {
          status.put("observation",starting?"start":"stop").put("observationElapsedMs",elapsed)
            .put("observationStatus",complete?(starting?"ready":"stopped"):(timeout?"timed-out":"pending"));
          if(expectedPort!=null)status.put("expectedListenerPort",expectedPort);
          if(expectedTransport!=null)status.put("expectedTransport",expectedTransport);
        }catch(Exception ignored){}
        String json="HELPER_SERVICE_STATUS\n"+status.toString();
        text.setText((complete?readyText:(timeout?"Helper service observation timed out":"Observing helper service "+(starting?"start":"stop")))+"\n"+json);
        text.setContentDescription(json);
        if(complete||timeout) {
          serviceObservationPending=false;
          for(Button button:serviceModeButtons)button.setEnabled(true);
        } else serviceObserver.postDelayed(this,250);
      }
    };
    poll.run();
  }
  private void startObservedService(TextView text,Intent intent,Integer expectedPort,String expectedTransport,String readyText) {
    try {startForegroundService(intent);observeService(text,true,expectedPort,expectedTransport,readyText);}
    catch(Exception error) {showServiceActionFailure(text,"start",error);}
  }
  private void showServiceActionFailure(TextView text,String action,Exception error) {
    ++serviceObservationGeneration;serviceObservationPending=false;
    for(Button button:serviceModeButtons)button.setEnabled(true);
    JSONObject status;
    try{status=RelayService.transportStatus();}catch(Exception ignored){status=new JSONObject();}
    try{status.put("observation",action).put("observationStatus","failed").put("actionErrorType",error.getClass().getSimpleName());}catch(Exception ignored){}
    showStatus(text,"HELPER_SERVICE_STATUS\n"+status.toString());
  }
  private static final class CaseSocket implements AutoCloseable {
    final Socket socket=new Socket();
    final Thread watchdog;
    CaseSocket(long deadlineMs) throws Exception {
      socket.connect(new InetSocketAddress("127.0.0.1",53318),10000);
      socket.setSoTimeout(15000);
      watchdog=new Thread(()->{try{Thread.sleep(deadlineMs);socket.close();}catch(Exception ignored){}},"transport-deadline");
      watchdog.setDaemon(true);watchdog.start();
    }
    public void close() throws Exception {watchdog.interrupt();socket.close();}
  }
  private static byte[] transportData(int seed,int offset,int length) {
    byte[] bytes=new byte[length];
    for(int i=0;i<length;i++)bytes[i]=(byte)((offset+i)*31+seed);
    return bytes;
  }
  private static void sendBytes(OutputStream out,MessageDigest hash,long[] count,byte[] data) throws Exception {
    out.write(data);out.flush();hash.update(data);count[0]+=data.length;
  }
  private static byte[] readLine(InputStream in,MessageDigest hash,long[] count) throws Exception {
    ByteArrayOutputStream out=new ByteArrayOutputStream();
    for(int b;(b=in.read())!=-1;) {out.write(b);hash.update((byte)b);count[0]++;if(out.size()>8192)throw new java.io.IOException("Control frame exceeded 8 KiB");if(b==10)return out.toByteArray();}
    throw new java.io.EOFException("Control frame incomplete");
  }
  private void transportProgress(TextView text,String phase,JSONArray cases,long started) {
    runOnUiThread(()->{String value="TRANSPORT_CONTROLS_RUNNING "+phase+" elapsedMs="+(android.os.SystemClock.elapsedRealtime()-started);
      text.setText(value);text.setContentDescription(value);});
  }
  private JSONObject transportCase(String name,int seed,int length,TextView text,JSONArray cases,long suiteStarted,AtomicReference<String> phase) throws Exception {
    long started=android.os.SystemClock.elapsedRealtime();
    MessageDigest sent=MessageDigest.getInstance("SHA-256"),received=MessageDigest.getInstance("SHA-256");
    long[] count={0},receivedCount={0};String sentSha256=null;
    try(CaseSocket control=new CaseSocket(name.equals("sparse")?370000:180000)) {
      Socket socket=control.socket;OutputStream out=socket.getOutputStream();InputStream in=socket.getInputStream();
      sendBytes(out,sent,count,("TC1 "+name+"\n").getBytes(StandardCharsets.US_ASCII));
      if(name.equals("duplex")) {
        sendBytes(out,sent,count,transportData(seed,0,32768));
        phase.set("duplex-challenge-before-eof");transportProgress(text,phase.get(),cases,suiteStarted);
        byte[] challenge=readLine(in,received,receivedCount);
        if(!"CHALLENGE\n".equals(new String(challenge,StandardCharsets.US_ASCII)))throw new java.io.IOException("Duplex challenge differs");
        phase.set("duplex-suffix-and-half-close");socket.setSoTimeout(120000);
        sendBytes(out,sent,count,transportData(seed,32768,length-32768));
      } else if(name.equals("sparse")) {
        byte[] open=readLine(in,received,receivedCount);
        if(!"SPARSE_OPEN\n".equals(new String(open,StandardCharsets.US_ASCII)))throw new java.io.IOException("Sparse open acknowledgement differs");
        long sparseStarted=android.os.SystemClock.elapsedRealtime();
        for(int i=0;i<13;i++) {
          long next=sparseStarted+i*25000L;
          while(android.os.SystemClock.elapsedRealtime()<next)Thread.sleep(Math.min(1000,next-android.os.SystemClock.elapsedRealtime()));
          sendBytes(out,sent,count,transportData(seed,i*64,64));
          byte[] ack=readLine(in,received,receivedCount);
          if(!("ACK "+i+"\n").equals(new String(ack,StandardCharsets.US_ASCII)))throw new java.io.IOException("Sparse heartbeat acknowledgement differs");
          transportProgress(text,"sparse-heartbeat-"+i,cases,suiteStarted);
        }
        long finish=sparseStarted+310000;
        while(android.os.SystemClock.elapsedRealtime()<finish)Thread.sleep(Math.min(1000,finish-android.os.SystemClock.elapsedRealtime()));
      } else {
        socket.setSoTimeout(120000);
        for(int offset=0;offset<length;offset+=32768)sendBytes(out,sent,count,transportData(seed,offset,Math.min(32768,length-offset)));
      }
      String sha256=hex(sent.digest());sentSha256=sha256;
      if(name.equals("cancel")) {
        socket.setSoTimeout(30000);
        boolean remoteClosed=false;String observed="eof";
        try {if(in.read()!=-1)throw new java.io.IOException("Cancelled peer unexpectedly returned data");remoteClosed=true;}
        catch(java.net.SocketException error) {remoteClosed=true;observed=error.getClass().getSimpleName();}
        return new JSONObject().put("case",name).put("count",count[0]).put("sha256",sha256).put("remoteClosed",remoteClosed)
          .put("receivedCount",0).put("receivedSha256",hex(received.digest()))
          .put("closeObservation",observed).put("shutdownOutput",false).put("elapsedMs",android.os.SystemClock.elapsedRealtime()-started)
          .put("helper",RelayService.transportStatus());
      }
      socket.shutdownOutput();
      byte[] reply=readLine(in,received,receivedCount);
      JSONObject returned=new JSONObject(new String(reply,StandardCharsets.UTF_8));
      if(returned.getLong("count")!=count[0]||!sha256.equals(returned.getString("sha256")))throw new java.io.IOException("Control byte/hash mismatch");
      if(in.read()!=-1)throw new java.io.IOException("Unexpected bytes after final control frame");
      return new JSONObject().put("case",name).put("count",count[0]).put("sha256",sha256)
        .put("receivedCount",receivedCount[0]).put("receivedSha256",hex(received.digest())).put("shutdownOutput",true)
        .put("replyReadThroughEof",true).put("elapsedMs",android.os.SystemClock.elapsedRealtime()-started)
        .put("challengeBeforeShutdownOutput",name.equals("duplex")).put("heartbeatAcks",name.equals("sparse")?13:0)
        .put("helper",RelayService.transportStatus());
    } catch(Exception error) {
      JSONObject partial=new JSONObject().put("case",name).put("status","failed").put("phase",phase.get())
        .put("count",count[0]).put("sha256",sentSha256==null?hex(sent.digest()):sentSha256)
        .put("receivedCount",receivedCount[0]).put("receivedSha256",hex(received.digest())).put("errorType",error.getClass().getSimpleName());
      synchronized(cases){cases.put(partial);}throw error;
    }
  }
  private void runTransportControls(TextView text,Button button) {
    if(transportControlBusy||reverseControlBusy||serviceObservationPending)return;
    transportControlBusy=true;button.setEnabled(false);
    new Thread(()->{
      long started=android.os.SystemClock.elapsedRealtime();JSONArray cases=new JSONArray();
      AtomicReference<String> phase=new AtomicReference<>("duplex-prefix");JSONObject result=new JSONObject();
      try {
        transportProgress(text,phase.get(),cases,started);
        cases.put(transportCase("duplex",11,32768+65537,text,cases,started,phase));
        phase.set("slow-receiver");transportProgress(text,phase.get(),cases,started);
        cases.put(transportCase("slow",29,8*1024*1024,text,cases,started,phase));
        phase.set("cancellation-isolation");transportProgress(text,phase.get(),cases,started);
        AtomicReference<JSONObject> cancel=new AtomicReference<>(),healthy=new AtomicReference<>();AtomicReference<Exception> failure=new AtomicReference<>();
        Thread cancelThread=new Thread(()->{try{cancel.set(transportCase("cancel",43,65536,text,cases,started,phase));}catch(Exception error){failure.compareAndSet(null,error);}},"transport-cancel");
        Thread healthyThread=new Thread(()->{try{healthy.set(transportCase("concurrent",61,1024*1024,text,cases,started,phase));}catch(Exception error){failure.compareAndSet(null,error);}},"transport-concurrent");
        cancelThread.start();healthyThread.start();cancelThread.join();healthyThread.join();
        if(cancel.get()!=null)cases.put(cancel.get());if(healthy.get()!=null)cases.put(healthy.get());
        if(failure.get()!=null)throw failure.get();
        phase.set("sparse-open-stream");transportProgress(text,phase.get(),cases,started);
        cases.put(transportCase("sparse",79,13*64,text,cases,started,phase));
        result.put("status","passed");
      } catch(Exception error) {
        try{result.put("status","failed").put("failedPhase",phase.get()).put("errorType",error.getClass().getSimpleName());}catch(Exception ignored){}
      } finally {
        try{result.put("cases",cases).put("elapsedMs",android.os.SystemClock.elapsedRealtime()-started).put("helper",RelayService.transportStatus());}catch(Exception ignored){}
        String value="TRANSPORT_CONTROLS_RESULT\n"+result.toString();
        runOnUiThread(()->{text.setText(value);text.setContentDescription(value);transportControlBusy=false;button.setEnabled(true);});
      }
    },"transport-controls").start();
  }
  private static String hex(byte[] bytes) {
    StringBuilder value=new StringBuilder();
    for(byte b:bytes)value.append(String.format("%02x",b&255));
    return value.toString();
  }
  private void runReverseControl(TextView text,Button button) {
    if(reverseControlBusy||transportControlBusy||serviceObservationPending)return;
    reverseControlBusy=true;button.setEnabled(false);
    showStatus(text,"REVERSE_CONTROL_RUNNING counts=0,1,65537\nTransport proof only; LocalSend is unchanged.");
    new Thread(()->{
      long started=android.os.SystemClock.elapsedRealtime();
      try {
        JSONArray results=new JSONArray();
        for(int count:new int[]{0,1,65537}) {
          byte[] data=new byte[count];
          for(int i=0;i<count;i++)data[i]=(byte)(i*31+7);
          String expected=hex(MessageDigest.getInstance("SHA-256").digest(data));
          long caseStarted=android.os.SystemClock.elapsedRealtime();
          try(Socket socket=new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1",53318),10000);
            socket.setSoTimeout(180000);
            socket.getOutputStream().write(data);socket.getOutputStream().flush();
            socket.shutdownOutput();
            ByteArrayOutputStream reply=new ByteArrayOutputStream();
            InputStream input=socket.getInputStream();byte[] chunk=new byte[1024];int n;
            while(true) {
              long remaining=180000-(android.os.SystemClock.elapsedRealtime()-caseStarted);
              if(remaining<=0)throw new java.net.SocketTimeoutException("Reverse control case exceeded 180 seconds");
              socket.setSoTimeout((int)remaining);
              n=input.read(chunk);if(n==-1)break;
              if(reply.size()+n>8192)throw new java.io.IOException("Reverse control reply exceeds 8 KiB");
              reply.write(chunk,0,n);
            }
            JSONObject returned=new JSONObject(new String(reply.toByteArray(),StandardCharsets.UTF_8));
            if(returned.getLong("count")!=count||!expected.equals(returned.getString("sha256"))) {
              throw new java.io.IOException("Reverse control byte/hash mismatch at count="+count);
            }
            results.put(new JSONObject().put("count",count).put("sha256",expected)
              .put("replyAfterShutdownOutput",true).put("replyReadThroughEof",true)
              .put("elapsedMs",android.os.SystemClock.elapsedRealtime()-caseStarted));
          }
        }
        String result="REVERSE_CONTROL_PASSED counts=0,1,65537\n"+results.toString()
          +"\nelapsedMs="+(android.os.SystemClock.elapsedRealtime()-started)
          +"\nTransport proof only; this does not reproduce a LocalSend failure.";
        runOnUiThread(()->showStatus(text,result));
      } catch(Exception error) {
        String result="REVERSE_CONTROL_FAILED "+error.getClass().getSimpleName()+": "+error.getMessage();
        runOnUiThread(()->showStatus(text,result));
      } finally {
        runOnUiThread(()->{reverseControlBusy=false;button.setEnabled(true);});
      }
    },"reverse-byte-control").start();
  }
  public void onCreate(Bundle state) {
    super.onCreate(state);
    if(getActionBar()!=null)getActionBar().hide();
    LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);
    layout.setOnApplyWindowInsetsListener((view,insets)->{
      view.setPadding(0,insets.getSystemWindowInsetTop(),0,insets.getSystemWindowInsetBottom());
      return insets;
    });
    TextView text=new TextView(this);text.setMaxLines(6);text.setText("Cloud transport helper\nSeparate diagnostic app. LocalSend is unchanged.");layout.addView(text);
    Button control=new Button(this);control.setText("Start socket control");control.setContentDescription("Start socket control");control.setAllCaps(false);layout.addView(control);
    Button actual=new Button(this);actual.setText("Relay to LocalSend");actual.setContentDescription("Relay to LocalSend");actual.setAllCaps(false);layout.addView(actual);
    Button reverse=new Button(this);reverse.setText("Relay from LocalSend");reverse.setContentDescription("Relay from LocalSend");reverse.setAllCaps(false);layout.addView(reverse);
    Button coalesced=new Button(this);coalesced.setText("Relay from LocalSend (coalesced)");coalesced.setContentDescription("Relay from LocalSend (coalesced)");coalesced.setAllCaps(false);layout.addView(coalesced);
    Button reverseControl=new Button(this);reverseControl.setText("Run reverse byte control");reverseControl.setContentDescription("Run reverse byte control");reverseControl.setAllCaps(false);layout.addView(reverseControl);
    Button transportControl=new Button(this);transportControl.setText("Run transport controls");transportControl.setContentDescription("Run transport controls");transportControl.setAllCaps(false);layout.addView(transportControl);
    Button stop=new Button(this);stop.setText("Stop helper");stop.setContentDescription("Stop helper");stop.setAllCaps(false);layout.addView(stop);
    Button metrics=new Button(this);metrics.setText("Show transport status");metrics.setContentDescription("Show transport status");metrics.setAllCaps(false);layout.addView(metrics);
    serviceModeButtons=new Button[]{control,actual,reverse,coalesced};
    control.setOnClickListener(v->startObservedService(text,new Intent(this,RelayService.class).putExtra("control",true),53319,null,"Socket control running"));
    actual.setOnClickListener(v->startObservedService(text,new Intent(this,RelayService.class).putExtra("control",false),null,null,"Relaying to LocalSend localhost:53317"));
    reverse.setOnClickListener(v->startObservedService(text,new Intent(this,RelayService.class).putExtra("reverse",true),53318,null,"Receiving LocalSend connections at localhost:53318"));
    coalesced.setOnClickListener(v->startObservedService(text,new Intent(this,RelayService.class).putExtra("reverse",true).putExtra("transport","coalesced"),53318,"coalesced","Receiving LocalSend connections (coalesced) at localhost:53318"));
    reverseControl.setOnClickListener(v->runReverseControl(text,reverseControl));
    transportControl.setOnClickListener(v->runTransportControls(text,transportControl));
    stop.setOnClickListener(v->{try{stopService(new Intent(this,RelayService.class));observeService(text,false,null,null,"Stopped");}catch(Exception error){showServiceActionFailure(text,"stop",error);}});
    metrics.setOnClickListener(v->{if(serviceObservationPending)return;try{showStatus(text,"HELPER_TRANSPORT_STATUS\n"+RelayService.transportStatus().toString());}catch(Exception error){showStatus(text,"HELPER_TRANSPORT_STATUS_FAILED "+error.getClass().getSimpleName());}});
    setContentView(layout);
    layout.requestApplyInsets();
  }
  public void onDestroy() {
    ++serviceObservationGeneration;serviceObserver.removeCallbacksAndMessages(null);super.onDestroy();
  }
}
