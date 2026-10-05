import 'dart:io' show Directory, FileSystemException, Platform;

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:path_provider/path_provider.dart' as path;

Future<String> getDefaultDestinationDirectory() async {
  if (!kIsWeb && Platform.isAndroid) {
    return await getDownloadsDirectoryAndroid() ?? '/storage/emulated/0/Download';
  }
  if (!kIsWeb && Platform.isIOS) {
    return (await path.getApplicationDocumentsDirectory()).path;
  }

  var downloadDir = await path.getDownloadsDirectory();
  if (downloadDir == null) {
    if (!kIsWeb && Platform.isWindows) {
      downloadDir = Directory('${Platform.environment['HOMEPATH']}/Downloads');
      if (!downloadDir.existsSync()) {
        downloadDir = Directory(Platform.environment['HOMEPATH']!);
      }
    } else {
      downloadDir = Directory('${Platform.environment['HOME']}/Downloads');
      if (!downloadDir.existsSync()) {
        downloadDir = Directory(Platform.environment['HOME']!);
      }
    }
  }
  try {
    // Downloads may be a link, including the macOS sandbox Downloads folder.
    return (await downloadDir.resolveSymbolicLinks()).replaceAll('\\', '/');
  } on FileSystemException {
    // Keep the path from the platform provider if it cannot be resolved.
  }
  return downloadDir.path.replaceAll('\\', '/');
}

Future<String> getCacheDirectory() async {
  final dir = await path.getTemporaryDirectory();
  await dir.create(recursive: true);
  return dir.path;
}
