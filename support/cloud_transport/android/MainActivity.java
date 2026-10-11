package org.localsend.cloudtransport;
import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.util.Log;
import android.widget.*;

public final class MainActivity extends Activity {
  public void onCreate(Bundle state) {
    super.onCreate(state);
    if(getActionBar()!=null)getActionBar().hide();
    LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);
    layout.setOnApplyWindowInsetsListener((view,insets)->{
      view.setPadding(0,insets.getSystemWindowInsetTop(),0,insets.getSystemWindowInsetBottom());
      return insets;
    });
    String configuredMode=null;
    String configFailure=null;
    try{configuredMode=RelayService.readConfig(this).getString("serviceMode");}
    catch(Exception e){configFailure=e.getClass().getSimpleName();Log.e("CloudTransport","Helper config failed: "+configFailure);}
    final String serviceMode=configuredMode;
    TextView text=new TextView(this);text.setText(serviceMode==null?"Helper config failed: "+configFailure:"Cloud transport helper\nService mode: "+serviceMode+"\nSeparate diagnostic app. LocalSend is unchanged.");layout.addView(text);
    Button control=new Button(this);control.setText("Start socket control");control.setContentDescription("Start socket control");control.setAllCaps(false);layout.addView(control);
    Button actual=new Button(this);actual.setText("Relay to LocalSend");actual.setContentDescription("Relay to LocalSend");actual.setAllCaps(false);layout.addView(actual);
    Button stop=new Button(this);stop.setText("Stop helper");stop.setContentDescription("Stop helper");stop.setAllCaps(false);layout.addView(stop);
    control.setEnabled(serviceMode!=null);actual.setEnabled(serviceMode!=null);
    control.setOnClickListener(v->{startRelay(true,serviceMode,text);});
    actual.setOnClickListener(v->{startRelay(false,serviceMode,text);});
    stop.setOnClickListener(v->{stopService(new Intent(this,RelayService.class));text.setText("Stopped\nService mode: "+(serviceMode==null?"unavailable":serviceMode));});
    setContentView(layout);
    layout.requestApplyInsets();
  }
  private void startRelay(boolean control,String serviceMode,TextView text){
    try{
      Intent intent=new Intent(this,RelayService.class).putExtra("control",control);
      if("ordinary".equals(serviceMode))startService(intent);
      else if("foreground".equals(serviceMode))startForegroundService(intent);
      else throw new IllegalArgumentException("Invalid service mode");
      text.setText((control?"Socket control running":"Relaying to LocalSend localhost:53317")+"\nService mode: "+serviceMode);
    }catch(Exception e){Log.e("CloudTransport","Helper launch failed: "+e.getClass().getSimpleName());text.setText("Helper launch failed: "+e.getClass().getSimpleName()+"\nService mode: "+serviceMode);}
  }
}
