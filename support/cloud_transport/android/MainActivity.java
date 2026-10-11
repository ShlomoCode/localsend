package org.localsend.cloudtransport;
import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.widget.*;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MainActivity extends Activity {
  private boolean reverseControlBusy;
  private static String hex(byte[] bytes) {
    StringBuilder value=new StringBuilder();
    for(byte b:bytes)value.append(String.format("%02x",b&255));
    return value.toString();
  }
  private void runReverseControl(TextView text,Button button) {
    if(reverseControlBusy)return;
    reverseControlBusy=true;button.setEnabled(false);
    text.setText("REVERSE_CONTROL_RUNNING counts=0,1,65537\nTransport proof only; LocalSend is unchanged.");
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
        runOnUiThread(()->text.setText(result));
      } catch(Exception error) {
        String result="REVERSE_CONTROL_FAILED "+error.getClass().getSimpleName()+": "+error.getMessage();
        runOnUiThread(()->text.setText(result));
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
    TextView text=new TextView(this);text.setText("Cloud transport helper\nSeparate diagnostic app. LocalSend is unchanged.");layout.addView(text);
    Button control=new Button(this);control.setText("Start socket control");control.setContentDescription("Start socket control");control.setAllCaps(false);layout.addView(control);
    Button actual=new Button(this);actual.setText("Relay to LocalSend");actual.setContentDescription("Relay to LocalSend");actual.setAllCaps(false);layout.addView(actual);
    Button reverse=new Button(this);reverse.setText("Relay from LocalSend");reverse.setContentDescription("Relay from LocalSend");reverse.setAllCaps(false);layout.addView(reverse);
    Button reverseControl=new Button(this);reverseControl.setText("Run reverse byte control");reverseControl.setContentDescription("Run reverse byte control");reverseControl.setAllCaps(false);layout.addView(reverseControl);
    Button stop=new Button(this);stop.setText("Stop helper");stop.setContentDescription("Stop helper");stop.setAllCaps(false);layout.addView(stop);
    control.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",true));text.setText("Socket control running");});
    actual.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",false));text.setText("Relaying to LocalSend localhost:53317");});
    reverse.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("reverse",true));text.setText("Receiving LocalSend connections at localhost:53318");});
    reverseControl.setOnClickListener(v->runReverseControl(text,reverseControl));
    stop.setOnClickListener(v->{stopService(new Intent(this,RelayService.class));text.setText("Stopped");});
    setContentView(layout);
    layout.requestApplyInsets();
  }
}
