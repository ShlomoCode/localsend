// Run with `dart support/diagnostics/windows_timestamp_probe.dart` after the
// PowerShell fixture generator on a Windows runner.
import 'dart:convert';
import 'dart:io';

const fixtureBytes = 'LocalSend timestamp fixture\n';

Future<void> main() async {
  final root = Platform.environment['LS_TIMESTAMP_FIXTURES'];
  if (root == null || root.isEmpty) {
    stderr.writeln('LS_TIMESTAMP_FIXTURES is not set. Run windows_timestamp_probe.ps1 first.');
    exitCode = 2;
    return;
  }

  final manifestPath = '$root${Platform.pathSeparator}manifest.json';
  final manifest = (jsonDecode(await File(manifestPath).readAsString()) as List<dynamic>).cast<Map<String, dynamic>>();
  final expectedBytes = ascii.encode(fixtureBytes);
  final results = <Map<String, dynamic>>[];
  var failures = 0;

  for (final item in manifest) {
    final name = item['name'] as String;
    final path = item['path'] as String;
    final directory = item['directory'] as String;
    final size = item['size'] as int;
    final file = File(path);
    final operations = <String, Map<String, dynamic>>{};

    Future<void> check(String operation, Future<Object?> Function() action, bool Function(Object?) valid) async {
      try {
        final value = await action();
        final passed = valid(value);
        operations[operation] = {'status': passed ? 'pass' : 'fail', 'actual': value?.toString()};
        if (!passed) failures++;
      } catch (error) {
        operations[operation] = {'status': 'error', 'error': error.toString()};
        failures++;
      }
    }

    await check('length', () => file.length(), (value) => value == size);
    await check('lengthSync', () async => file.lengthSync(), (value) => value == size);
    await check('stat', () async {
      final stat = await file.stat();
      return {'size': stat.size, 'modified': stat.modified.toUtc().toIso8601String(), 'type': stat.type.toString()};
    }, (value) => (value as Map<String, dynamic>)['size'] == size && value['type'] == FileSystemEntityType.file.toString());
    await check('statSync', () async {
      final stat = file.statSync();
      return {'size': stat.size, 'modified': stat.modified.toUtc().toIso8601String(), 'type': stat.type.toString()};
    }, (value) => (value as Map<String, dynamic>)['size'] == size && value['type'] == FileSystemEntityType.file.toString());
    await check(
      'directoryList',
      () async => Directory(directory).list().map((entity) => entity.path).toList(),
      (value) => (value as List<String>).contains(path),
    );
    await check(
      'directoryListSync',
      () async => Directory(directory).listSync().map((entity) => entity.path).toList(),
      (value) => (value as List<String>).contains(path),
    );
    await check('read', () => file.readAsBytes(), (value) => _sameBytes(value as List<int>, expectedBytes));
    await check('readSync', () async => file.readAsBytesSync(), (value) => _sameBytes(value as List<int>, expectedBytes));

    results.add({'name': name, 'timestamp': item['timestamp'], 'path': path, 'expectedSize': size, 'operations': operations});
    stdout.writeln('$name: ${operations.entries.map((entry) => '${entry.key}=${entry.value['status']}').join(', ')}');
  }

  final output = Platform.environment['LS_DIAGNOSTIC_OUTPUT'] ?? root;
  await Directory(output).create(recursive: true);
  final reportPath = '$output${Platform.pathSeparator}dart-report.json';
  await File(reportPath).writeAsString('${jsonEncode({'fixtureRoot': root, 'manifest': manifestPath, 'failures': failures, 'cases': results})}\n');
  stdout.writeln('Dart probe report: $reportPath');
  if (failures != 0) exitCode = 1;
}

bool _sameBytes(List<int> actual, List<int> expected) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}
