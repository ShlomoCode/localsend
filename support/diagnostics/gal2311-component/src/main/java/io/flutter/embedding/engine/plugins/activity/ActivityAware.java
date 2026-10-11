package io.flutter.embedding.engine.plugins.activity;
public interface ActivityAware {
    void onAttachedToActivity(ActivityPluginBinding binding);
    void onDetachedFromActivityForConfigChanges();
    void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding);
    void onDetachedFromActivity();
}
