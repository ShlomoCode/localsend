package io.flutter.plugin.common;
public final class MethodChannel {
    public interface MethodCallHandler {void onMethodCall(MethodCall call,Result result);}
    public interface Result {void success(Object value);void error(String code,String message,Object details);void notImplemented();}
    public MethodChannel(BinaryMessenger messenger,String name){}
    public void setMethodCallHandler(MethodCallHandler handler){}
}
