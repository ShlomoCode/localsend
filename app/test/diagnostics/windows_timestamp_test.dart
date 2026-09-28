// Windows filesystem diagnostic for the timestamp boundary cases in #3366.
// A PowerShell harness creates real files and sets their timestamps before this
// test runs. It passes LS_TIMESTAMP_FIXTURES (a directory with manifest.json)
// and LS_RUST_LIBRARY (the built rust_lib_localsend_app.dll).
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isWindows) {
    test(
      'Windows filesystem timestamp diagnostic',
      () {},
      skip: 'Requires Windows filesystem timestamps and the Rust DLL',
    );
    return;
  }

  final fixturesRoot = Platform.environment['LS_TIMESTAMP_FIXTURES'];
  final rustLibrary = Platform.environment['LS_RUST_LIBRARY'];
  if (fixturesRoot == null || rustLibrary == null) {
    test('timestamp fixture harness is configured', () {
      fail(
        'Set LS_TIMESTAMP_FIXTURES and LS_RUST_LIBRARY using the Windows fixture harness.',
      );
    });
    return;
  }

  final manifestFile = File(p.join(fixturesRoot, 'manifest.json'));
  if (!manifestFile.existsSync()) {
    test(
      'timestamp fixture manifest exists',
      () => fail('Missing ${manifestFile.path}'),
    );
    return;
  }

  final cases = (jsonDecode(manifestFile.readAsStringSync()) as List<dynamic>).cast<Map<String, dynamic>>();
  if (cases.isEmpty) {
    test(
      'timestamp fixture manifest has cases',
      () => fail('Empty ${manifestFile.path}'),
    );
    return;
  }

  setUpAll(() async {
    expect(
      File(rustLibrary).existsSync(),
      isTrue,
      reason: 'Build the Rust DLL at $rustLibrary before running the diagnostic',
    );
    await RustLib.init(externalLibrary: ExternalLibrary.open(rustLibrary));
  });

  tearDownAll(RustLib.dispose);

  for (final fixture in cases) {
    final name = fixture['name'] as String;
    final path = fixture['path'] as String;
    final directory = fixture['directory'] as String;
    final timestamp = fixture['timestamp'] as String;
    final size = fixture['size'] as int;

    test('$name: XFile conversion preserves the real modified time', () async {
      final converted = await CrossFileConverters.convertXFile(XFile(path));
      _expectFile(converted, path: path, name: p.basename(path), size: size, timestamp: timestamp);
    });

    test('$name: AddFilesAction preserves the real modified time', () async {
      final container = RefenaContainer();
      try {
        await container
            .redux(selectedSendingFilesProvider)
            .dispatchAsync(
              AddFilesAction<XFile>(files: [XFile(path)], converter: CrossFileConverters.convertXFile),
            );
        final selected = container.read(selectedSendingFilesProvider);
        expect(selected, hasLength(1), reason: 'File selection must include exactly the fixture file');
        _expectFile(selected.single, path: path, name: p.basename(path), size: size, timestamp: timestamp);
      } finally {
        container.disposeContainer();
      }
    });

    test('$name: AddDirectoryAction preserves the real modified time', () async {
      final container = RefenaContainer();
      try {
        await container.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory));
        final selected = container.read(selectedSendingFilesProvider);
        expect(selected, hasLength(1), reason: 'Each fixture directory must contain exactly one selected file');
        final relative = p.relative(path, from: directory).replaceAll('\\', '/');
        _expectFile(selected.single, path: path, name: '${p.basename(directory)}/$relative', size: size, timestamp: timestamp);
      } finally {
        container.disposeContainer();
      }
    });
  }
}

void _expectFile(
  CrossFile file, {
  required String path,
  required String name,
  required int size,
  required String timestamp,
}) {
  expect(file.name, name);
  expect(file.path, path);
  expect(file.size, size);
  expect(file.bytes, isNull);
  expect(
    file.lastModified,
    isNotNull,
    reason: 'Rust did not return a modified timestamp for $path',
  );
  expect(
    DateTime.parse(file.lastModified!).toUtc(),
    DateTime.parse(timestamp).toUtc(),
    reason: 'Modified timestamp changed for $path',
  );
  expect(
    file.lastAccessed,
    isNotNull,
    reason: 'Rust did not return an access timestamp for $path',
  );
  expect(
    () => DateTime.parse(file.lastAccessed!),
    returnsNormally,
    reason: 'Access timestamp is not ISO 8601 for $path',
  );
}
