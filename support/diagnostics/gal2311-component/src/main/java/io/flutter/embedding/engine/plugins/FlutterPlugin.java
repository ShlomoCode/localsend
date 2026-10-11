package io.flutter.embedding.engine.plugins;
import android.content.Context;
import io.flutter.plugin.common.BinaryMessenger;
public interface FlutterPlugin {
    void onAttachedToEngine(FlutterPluginBinding binding);
    void onDetachedFromEngine(FlutterPluginBinding binding);
    final class FlutterPluginBinding {
        private final Context context;
        public FlutterPluginBinding(Context context){this.context=context;}
        public Context getApplicationContext(){return context;}
        public BinaryMessenger getBinaryMessenger(){return null;}
    }
}
