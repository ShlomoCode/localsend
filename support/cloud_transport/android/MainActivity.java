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
    Button control=new Button(this);control.setText("Start socket control");layout.addView(control);
    Button actual=new Button(this);actual.setText("Relay to LocalSend");layout.addView(actual);
    Button stop=new Button(this);stop.setText("Stop helper");layout.addView(stop);
    control.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",true));text.setText("Socket control running");});
    actual.setOnClickListener(v->{startForegroundService(new Intent(this,RelayService.class).putExtra("control",false));text.setText("Relaying to LocalSend localhost:53317");});
    stop.setOnClickListener(v->{stopService(new Intent(this,RelayService.class));text.setText("Stopped");});
    setContentView(layout);
  }
}
