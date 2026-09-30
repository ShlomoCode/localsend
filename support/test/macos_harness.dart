import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs the macOS startup regression with the dedicated native harness flavor.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 &&
      (arguments.single == '--help' || arguments.single == '-h')) {
    stdout.writeln(
      'Run from the repository root: fvm dart run support/test/macos_harness.dart',
    );
    stdout.writeln(
      'Requires macOS, Xcode, FVM, and the pinned Flutter and Rust toolchains.',
    );
    return;
  }
  if (arguments.isNotEmpty) {
    stderr.writeln('Unknown arguments: ${arguments.join(' ')}');
    exitCode = 64;
    return;
  }
  if (!Platform.isMacOS) {
    stderr.writeln('The macOS startup harness must run on macOS.');
    exitCode = 69;
    return;
  }

  final repository = File.fromUri(
    Platform.script,
  ).parent.parent.parent.absolute;
  if (!File('${repository.path}/.fvmrc').existsSync()) {
    stderr.writeln(
      'Cannot locate the LocalSend repository from ${Platform.script}.',
    );
    exitCode = 66;
    return;
  }

  final artifactDirectory = Directory('${repository.path}/artifacts')
    ..createSync(recursive: true);
  final log = File('${artifactDirectory.path}/macos-startup.log').openWrite();
  try {
    final commands = <(String, List<String>, String)>[
      ('fvm', ['flutter', 'pub', 'get'], '${repository.path}/app'),
      (
        'fvm',
        ['flutter', 'pub', 'get'],
        '${repository.path}/packages/localsend_isolates/rust_builder/cargokit/build_tool',
      ),
      (
        'fvm',
        [
          'flutter',
          'test',
          'integration_test/macos_startup_test.dart',
          '--flavor',
          'harness',
          '-d',
          'macos',
          '--reporter',
          'expanded',
        ],
        '${repository.path}/app',
      ),
    ];
    for (final (executable, args, directory) in commands) {
      final command = '$executable ${args.join(' ')}';
      stdout.writeln('\n$command');
      log.writeln('\n$command');
      final result = await _run(executable, args, directory, log);
      if (result != 0) {
        final message =
            'Harness stopped after $command (exit $result). Log: ${_logFilePath(artifactDirectory)}';
        stderr.writeln(message);
        log.writeln(message);
        exitCode = result;
        return;
      }
    }
    final message =
        'macOS startup regression passed. Log: ${_logFilePath(artifactDirectory)}';
    stdout.writeln(message);
    log.writeln(message);
  } on ProcessException catch (error) {
    final message = 'Could not start ${error.executable}: ${error.message}';
    stderr.writeln(message);
    log.writeln(message);
    exitCode = 69;
  } finally {
    await log.flush();
    await log.close();
  }
}

String _logFilePath(Directory artifactDirectory) =>
    '${artifactDirectory.path}/macos-startup.log';

Future<int> _run(
  String executable,
  List<String> arguments,
  String directory,
  IOSink log,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory,
  );
  final output = process.stdout.transform(utf8.decoder).listen((chunk) {
    stdout.write(chunk);
    log.write(chunk);
  });
  final errors = process.stderr.transform(utf8.decoder).listen((chunk) {
    stderr.write(chunk);
    log.write(chunk);
  });
  final drained = Future.wait([
    output.asFuture<void>(),
    errors.asFuture<void>(),
  ]);
  final result = await process.exitCode;
  await drained;
  return result;
}
