import 'package:flutter/services.dart';

const _methodChannel = MethodChannel('org.localsend.localsend_app/window-placement');

Future<Map<String, int>> getWindowPlacement() async {
  final placement = await _methodChannel.invokeMapMethod<String, int>('getWindowPlacement');
  return placement!;
}

Future<bool> restoreWindowPlacement(Map<String, int> placement) async {
  return await _methodChannel.invokeMethod<bool>('restoreWindowPlacement', placement) ?? false;
}
