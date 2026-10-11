package org.localsend.cloudtransport;
import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.widget.*;

public final class MainActivity extends Activity {
  public void onCreate(Bundle state) {
    super.onCreate(state);
    LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);
    TextView text=new TextView(this);text.setText("Cloud transport helper\nSeparate diagnostic app. LocalSend is unchanged.");layout.addView(text);
    Button control=new Button(this);control.setText("Start socket control");control.setContentDescription("Start socket control");control.setAllCaps(false);layout.addView(control);
    Button actual=new Button(this);actual.setText("Relay to LocalSend");actual.setContentDescription("Relay to LocalSend");actual.setAllCaps(false);layout.addView(actual);
    Button stop=new Button(this);stop.setText("Stop helper");stop.setContentDescription("Stop helper");stop.setAllCaps(false);layout.addView(stop);
    control.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",true));text.setText("Socket control running");});
    actual.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",false));text.setText("Relaying to LocalSend localhost:53317");});
    stop.setOnClickListener(v->{stopService(new Intent(this,RelayService.class));text.setText("Stopped");});
    Button permission=new Button(this);permission.setText("Observer storage access");permission.setContentDescription("Observer storage access");layout.addView(permission);
    permission.setOnClickListener(v->startActivity(new Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, android.net.Uri.parse("package:"+getPackageName()))));
    Button observe=new Button(this);observe.setText("Observe owned storage");observe.setContentDescription("Observe owned storage");layout.addView(observe);
    observe.setOnClickListener(v->{try {org.json.JSONObject report=StorageObserver.collect(this);text.setText("Observer complete; allFilesAccess="+report.getBoolean("allFilesAccess"));}catch(Exception error){text.setText("Observer failed: "+error);}});
    EditText scanName=new EditText(this);scanName.setContentDescription("Owned scan filename");layout.addView(scanName);
    Button scan=new Button(this);scan.setText("Finalize owned received file");scan.setContentDescription("Finalize owned received file");layout.addView(scan);
    scan.setOnClickListener(v->{text.setText("Scan pending");try {StorageObserver.finalizeOwnedFile(this,scanName.getText().toString(),result->text.setText("Scan completed"));}catch(Exception error){text.setText("Scan failed: "+error);}});
    setContentView(layout);
  }
}
