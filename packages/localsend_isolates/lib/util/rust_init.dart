import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

Future<void> initRustLib() async {
  final config = RustLib.kDefaultExternalLibraryLoaderConfig;
  await RustLib.init(
    externalLibrary: await loadExternalLibrary(
      ExternalLibraryLoaderConfig(
        stem: config.stem,
        // Resolve bundled Linux libraries without relying on the Flutter engine's RUNPATH.
        ioDirectory: Platform.isLinux ? Directory(p.join(p.dirname(Platform.resolvedExecutable), 'lib')).uri.toString() : config.ioDirectory,
        webPrefix: config.webPrefix,
        wasmBindgenName: config.wasmBindgenName,
      ),
    ),
  );
}
