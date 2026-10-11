package org.localsend.cloudtransport;
import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.widget.*;

public final class MainActivity extends Activity {
  private TextView metadataOutput;
  private EditText metadataFilename;
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
    Button stop=new Button(this);stop.setText("Stop helper");stop.setContentDescription("Stop helper");stop.setAllCaps(false);layout.addView(stop);
    control.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",true));text.setText("Socket control running");});
    actual.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",false));text.setText("Relaying to LocalSend localhost:53317");});
    stop.setOnClickListener(v->{stopService(new Intent(this,RelayService.class));text.setText("Stopped");});
    metadataFilename=new EditText(this);metadataFilename.setHint("Metadata filename");metadataFilename.setContentDescription("Metadata filename");layout.addView(metadataFilename);
    Button metadata=new Button(this);metadata.setText("Read image metadata");metadata.setContentDescription("Read image metadata");metadata.setAllCaps(false);layout.addView(metadata);
    metadataOutput=new TextView(this);layout.addView(metadataOutput);
    metadata.setOnClickListener(v->{
      String permission=android.os.Build.VERSION.SDK_INT>=33?"android.permission.READ_MEDIA_IMAGES":"android.permission.READ_EXTERNAL_STORAGE";
      if(checkSelfPermission(permission)!=android.content.pm.PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{permission},2311);}
      else readMetadata();
    });
    setContentView(layout);
    layout.requestApplyInsets();
  }
  public void onRequestPermissionsResult(int code,String[] permissions,int[] grants){super.onRequestPermissionsResult(code,permissions,grants);if(code==2311)readMetadata();}
  private void readMetadata(){
    String result=ImageMetadata.read(this,metadataFilename.getText().toString());
    metadataOutput.setText(result);metadataOutput.setContentDescription("Image metadata: "+result);
  }
}
