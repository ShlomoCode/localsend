package io.flutter.embedding.engine.plugins.activity;
import android.app.Activity;
import io.flutter.plugin.common.PluginRegistry;
public interface ActivityPluginBinding {
    Activity getActivity();
    void addRequestPermissionsResultListener(PluginRegistry.RequestPermissionsResultListener listener);
}
