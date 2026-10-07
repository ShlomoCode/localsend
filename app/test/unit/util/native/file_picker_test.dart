import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/dialogs/loading_dialog.dart';
import 'package:localsend_app/widget/dialogs/no_permission_dialog.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.localsend.localsend_app/localsend');
  const permissionsChannel = MethodChannel('flutter.baseflow.com/permissions/methods');

  for (final option in [FilePickerOption.file, FilePickerOption.folder]) {
    for (final errorCode in ['PICKER_FAILED', 'PERMISSION_DENIED', 'CANCELED']) {
      testWidgets('$option with $errorCode shows the appropriate result', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        var pickerCalled = false;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == (option == FilePickerOption.file ? 'pickFiles' : 'pickDirectory')) {
            pickerCalled = true;
            throw PlatformException(code: errorCode, message: 'Document provider failed');
          }
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(permissionsChannel, (call) async => {15: 1});
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(permissionsChannel, null));

        await tester.pumpWidget(
          RefenaScope(
            overrides: [
              deviceInfoProvider.overrideWithBuilder(
                (_) => DeviceInfoResult(deviceType: DeviceType.mobile, deviceModel: null, androidSdkInt: 35),
              ),
            ],
            child: MaterialApp(
              navigatorKey: Routerino.navigatorKey,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => context.global.dispatchAsync(PickFileAction(option: option, context: context)),
                    child: const Text('Pick'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Pick'));
        await tester.pump(const Duration(milliseconds: 300)); // The folder picker waits for its loading dialog.
        await tester.pumpAndSettle();

        expect(pickerCalled, isTrue);
        expect(find.byType(LoadingDialog), findsNothing);
        if (errorCode == 'CANCELED') {
          expect(find.byType(ErrorDialog), findsNothing);
          expect(find.byType(NoPermissionDialog), findsNothing);
        } else if (errorCode == 'PERMISSION_DENIED') {
          expect(find.byType(NoPermissionDialog), findsOneWidget);
          expect(find.byType(ErrorDialog), findsNothing);
        } else {
          expect(find.byType(ErrorDialog), findsOneWidget);
          expect(find.textContaining('Document provider failed'), findsOneWidget);
          expect(find.byType(NoPermissionDialog), findsNothing);
        }

        if (errorCode != 'CANCELED') {
          await tester.tap(find.byType(TextButton).last);
          await tester.pumpAndSettle();
          expect(find.byType(ErrorDialog), findsNothing);
          expect(find.byType(NoPermissionDialog), findsNothing);
        }
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  for (final option in [FilePickerOption.file, FilePickerOption.folder]) {
    testWidgets('$option on desktop leaves the current page open after a picker error', (tester) async {
      final originalSelector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _FailingFileSelector();
      addTearDown(() => FileSelectorPlatform.instance = originalSelector);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(
        RefenaScope(
          child: MaterialApp(
            navigatorKey: Routerino.navigatorKey,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        body: Column(
                          children: [
                            const Text('Picker page'),
                            TextButton(
                              onPressed: () => context.global.dispatchAsync(PickFileAction(option: option, context: context)),
                              child: const Text('Pick'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open page'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorDialog), findsOneWidget);
      expect(find.textContaining('Document provider failed'), findsOneWidget);
      expect(find.byType(NoPermissionDialog), findsNothing);
      expect(find.byType(LoadingDialog), findsNothing);

      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      expect(find.text('Picker page'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
      FileSelectorPlatform.instance = originalSelector;
    });
  }

  for (final option in [FilePickerOption.file, FilePickerOption.folder]) {
    testWidgets('$option preserves the current page if its loading route is removed while picking', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final pickerResult = Completer<dynamic>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == (option == FilePickerOption.file ? 'pickFiles' : 'pickDirectory')) {
          return pickerResult.future;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(permissionsChannel, (call) async => {15: 1});
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(permissionsChannel, null));

      await tester.pumpWidget(
        RefenaScope(
          overrides: [
            deviceInfoProvider.overrideWithBuilder(
              (_) => DeviceInfoResult(deviceType: DeviceType.mobile, deviceModel: null, androidSdkInt: 35),
            ),
          ],
          child: MaterialApp(
            navigatorKey: Routerino.navigatorKey,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        body: Column(
                          children: [
                            const Text('Picker page'),
                            TextButton(
                              onPressed: () => context.global.dispatchAsync(PickFileAction(option: option, context: context)),
                              child: const Text('Pick'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open page'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LoadingDialog), findsOneWidget);

      // Simulate the loading route disappearing before the platform picker completes.
      Routerino.navigatorKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LoadingDialog), findsNothing);

      pickerResult.completeError(PlatformException(code: 'PICKER_FAILED', message: 'Document provider failed'));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorDialog), findsOneWidget);
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      expect(find.text('Picker page'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}

class _FailingFileSelector extends FileSelectorPlatform {
  @override
  Future<List<XFile>> openFiles({List<XTypeGroup>? acceptedTypeGroups, String? initialDirectory, String? confirmButtonText}) {
    throw PlatformException(code: 'PICKER_FAILED', message: 'Document provider failed');
  }

  @override
  Future<String?> getDirectoryPath({String? initialDirectory, String? confirmButtonText}) {
    throw PlatformException(code: 'PICKER_FAILED', message: 'Document provider failed');
  }
}
