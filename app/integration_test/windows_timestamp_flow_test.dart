// Runs on a Windows desktop runner with the real picker plugins and Rust DLL.
// The diagnostic workflow creates timestamp fixtures and sets the environment
// variables before `flutter test integration_test/... -d windows` starts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/dialogs/loading_dialog.dart';
import 'package:localsend_app/widget/dialogs/no_permission_dialog.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isWindows || Platform.environment['LS_WINDOWS_DIAGNOSTIC'] != '1') {
    test('Windows picker integration diagnostic', () {}, skip: 'Run through the Windows timestamp diagnostic workflow');
    return;
  }

  final fixturesRoot = Platform.environment['LS_TIMESTAMP_FIXTURES'];
  final rustLibrary = Platform.environment['LS_RUST_LIBRARY'];
  final workspace = Platform.environment['GITHUB_WORKSPACE'] ?? p.dirname(Directory.current.path);
  final automationScript = Platform.environment['LS_DIALOG_DRIVER'] ?? p.join(workspace, 'support', 'diagnostics', 'windows_dialog_select.ps1');
  if (fixturesRoot == null || rustLibrary == null) {
    test('integration fixture harness is configured', () => fail('LS_TIMESTAMP_FIXTURES and LS_RUST_LIBRARY are required'));
    return;
  }

  final manifestFile = File(p.join(fixturesRoot, 'manifest.json'));
  if (!manifestFile.existsSync()) {
    test('integration fixture manifest exists', () => fail('Missing ${manifestFile.path}'));
    return;
  }
  final cases = (jsonDecode(manifestFile.readAsStringSync()) as List<dynamic>).cast<Map<String, dynamic>>();
  if (cases.isEmpty) {
    test('integration fixture manifest has cases', () => fail('Empty ${manifestFile.path}'));
    return;
  }

  setUpAll(() async {
    expect(File(rustLibrary).existsSync(), isTrue, reason: 'Missing built Rust DLL: $rustLibrary');
    expect(File(automationScript).existsSync(), isTrue, reason: 'Missing picker automation: $automationScript');
    await RustLib.init(externalLibrary: ExternalLibrary.open(rustLibrary));
  });
  tearDownAll(RustLib.dispose);

  for (final fixture in cases) {
    final name = fixture['name'] as String;
    final path = fixture['path'] as String;
    final directory = fixture['directory'] as String;
    final timestamp = fixture['timestamp'] as String;
    final size = fixture['size'] as int;

    testWidgets('$name: native file picker reaches app selection', (tester) async {
      final container = RefenaContainer();
      try {
        final context = await _mountPickerContext(tester, container);
        if (!context.mounted) fail('Picker context detached before file selection');
        await _exercisePicker(
          tester: tester,
          script: automationScript,
          mode: 'File',
          target: path,
          dispatch: () => context.ref.global.dispatchAsync(PickFileAction(option: FilePickerOption.file, context: context)),
        );
        expect(find.byType(NoPermissionDialog), findsNothing, reason: 'The app reported a file-picker error for $path');
        final selected = container.read(selectedSendingFilesProvider);
        expect(selected, hasLength(1), reason: 'The file picker should select exactly one file');
        _expectSelected(selected.single, path: path, name: p.basename(path), size: size, timestamp: timestamp);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.disposeContainer();
      }
    });

    testWidgets('$name: native folder picker reaches app selection', (tester) async {
      final container = RefenaContainer();
      try {
        final context = await _mountPickerContext(tester, container);
        if (!context.mounted) fail('Picker context detached before folder selection');
        await _exercisePicker(
          tester: tester,
          script: automationScript,
          mode: 'Folder',
          target: directory,
          dispatch: () => context.ref.global.dispatchAsync(PickFileAction(option: FilePickerOption.folder, context: context)),
        );
        expect(find.byType(NoPermissionDialog), findsNothing, reason: 'The app reported a folder-picker error for $directory');
        final selected = container.read(selectedSendingFilesProvider);
        expect(selected, hasLength(1), reason: 'The folder picker should select exactly one file');
        final relative = p.relative(path, from: directory).replaceAll('\\', '/');
        _expectSelected(selected.single, path: path, name: '${p.basename(directory)}/$relative', size: size, timestamp: timestamp);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.disposeContainer();
      }
    });
  }
}

Future<BuildContext> _mountPickerContext(WidgetTester tester, RefenaContainer container) async {
  Routerino.navigatorKey = GlobalKey<NavigatorState>();
  BuildContext? pickerContext;
  await tester.pumpWidget(
    RefenaScope.withContainer(
      container: container,
      ownsContainer: false,
      child: MaterialApp(
        navigatorKey: Routerino.navigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pickerContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  final context = pickerContext;
  if (context == null || !context.mounted) fail('Picker context did not mount');
  return context;
}

Future<void> _exercisePicker({
  required WidgetTester tester,
  required String script,
  required String mode,
  required String target,
  required Future<void> Function() dispatch,
}) async {
  final warnings = <String>[];
  final subscription = Logger.root.onRecord.listen((record) {
    if (record.loggerName == 'FilePickerHelper' && record.level >= Level.WARNING) {
      warnings.add('${record.level.name}: ${record.message}; error=${record.error}; stack=${record.stackTrace}');
    }
  });
  try {
    Future<void>? action;
    if (mode == 'Folder') {
      action = dispatch();
      await tester.pump();
      expect(
        find.byType(LoadingDialog),
        findsOneWidget,
        reason: 'The folder action should display its loading dialog before opening the native picker',
      );
    }
    final automation = (await tester.runAsync(() => _startAutomation(script: script, mode: mode, target: target)))!;
    if (mode == 'File') {
      action = dispatch();
    } else {
      // The app delays the native folder picker by 200 ms to show the loading
      // route. Advance that timer only after the automation process is ready.
      await tester.pump(const Duration(milliseconds: 250));
    }
    final result = (await tester.runAsync(() => _waitAutomation(automation, action!)))!;
    var actionCompleted = false;
    Object? actionError;
    unawaited(
      result.action.then(
        (_) => actionCompleted = true,
        onError: (Object error, StackTrace stack) {
          actionError = error;
          actionCompleted = true;
        },
      ),
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(NoPermissionDialog).evaluate().isNotEmpty) {
        Routerino.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await result.action.timeout(const Duration(seconds: 5));
        fail(
          'App opened NoPermissionDialog after native picker. Automation: ${result.stdout}; stderr: ${result.stderr}; '
          'FilePickerHelper warnings: $warnings',
        );
      }
      if (actionCompleted) break;
    }
    expect(result.exitCode, 0, reason: 'Native picker automation failed. ${result.stdout}; stderr: ${result.stderr}; warnings: $warnings');
    expect(actionCompleted, isTrue, reason: 'PickFileAction did not complete. ${result.stdout}; stderr: ${result.stderr}; warnings: $warnings');
    if (actionError != null) fail('PickFileAction threw $actionError; native trace: ${result.stdout}; warnings: $warnings');
    await result.action;
    await tester.pumpAndSettle();
    expect(find.byType(NoPermissionDialog), findsNothing, reason: 'App opened NoPermissionDialog; warnings: $warnings');
    // Keep the native control trace next to the app selection assertion in CI.
    stdout.writeln('Native picker trace: ${result.stdout}');
  } finally {
    await subscription.cancel();
  }
}

Future<Process> _startAutomation({
  required String script,
  required String mode,
  required String target,
}) async {
  return Process.start('powershell.exe', [
    '-NoProfile',
    '-STA',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script,
    '-TargetProcessId',
    '$pid',
    '-Path',
    target,
    '-Mode',
    mode,
    '-TimeoutSeconds',
    '15',
  ]);
}

Future<_DialogResult> _waitAutomation(Process automation, Future<void> action) async {
  final output = automation.stdout.transform(utf8.decoder).join();
  final errors = automation.stderr.transform(utf8.decoder).join();
  try {
    final code = await automation.exitCode.timeout(const Duration(seconds: 25));
    final stdoutLog = await output;
    final stderrLog = await errors;
    return _DialogResult(exitCode: code, stdout: stdoutLog, stderr: stderrLog, action: action);
  } finally {
    automation.kill();
  }
}

class _DialogResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final Future<void> action;

  const _DialogResult({required this.exitCode, required this.stdout, required this.stderr, required this.action});
}

void _expectSelected(CrossFile file, {required String path, required String name, required int size, required String timestamp}) {
  expect(file.name, name);
  expect(p.normalize(file.path!).toLowerCase(), p.normalize(path).toLowerCase());
  expect(file.size, size);
  expect(file.bytes, isNull);
  expect(file.lastModified, isNotNull, reason: 'Rust did not return modified time for $path');
  expect(DateTime.parse(file.lastModified!).toUtc(), DateTime.parse(timestamp).toUtc(), reason: 'Modified time changed for $path');
  expect(file.lastAccessed, isNotNull, reason: 'Rust did not return access time for $path');
  expect(() => DateTime.parse(file.lastAccessed!), returnsNormally);
}
