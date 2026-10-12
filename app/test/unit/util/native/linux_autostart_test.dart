import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/linux_autostart.dart';

void main() {
  const executable = '/opt/Local Send/quo"te\\percent%cash\$`/localsend';
  test('desktop command round trips reserved characters and a separate hidden argument', () {
    final contents = serializeLinuxAutoStartEntry('LocalSend', [executable, '--hidden']);
    final state = parseLinuxAutoStartEntry(contents, [executable]);
    expect(state?.enabled, true);
    expect(state?.hidden, true);
  });

  test('desktop overrides disable registration without losing the launch argument', () {
    final contents = serializeLinuxAutoStartEntry('LocalSend', ['/opt/localsend', '--hidden']);
    for (final override in ['Hidden=true', 'X-GNOME-Autostart-enabled=false']) {
      final state = parseLinuxAutoStartEntry('$contents$override\n', ['/opt/localsend']);
      expect(state?.enabled, false);
      expect(state?.hidden, true);
    }
  });

  test('hidden text in executable or metadata is not a hidden argument', () {
    final contents = serializeLinuxAutoStartEntry('LocalSend --hidden', ['/opt/--hidden/localsend']);
    expect(parseLinuxAutoStartEntry(contents, ['/opt/--hidden/localsend'])?.hidden, false);
    expect(parseLinuxAutoStartEntry('$contents' 'Exec=/other/app\n', ['/opt/--hidden/localsend']), null);
  });

  test('unknown field codes and malformed quoting are unavailable', () {
    for (final exec in ['/opt/localsend %f', '"/opt/localsend', '/opt/localsend --hidden-extra']) {
      expect(parseLinuxAutoStartEntry('[Desktop Entry]\nType=Application\nName=LocalSend\nExec=$exec\n', ['/opt/localsend']), null);
    }
  });

  group('registration visibility and mutation', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('localsend-autostart-test-'));
    tearDown(() => root.deleteSync(recursive: true));

    LinuxAutoStart resolve({String? scope, Map<String, String>? environment, String? hostConfig}) => LinuxAutoStart.resolve(
      environment: environment ?? {'HOME': root.path, 'XDG_CONFIG_HOME': '${root.path}/config'},
      executable: '/opt/localsend',
      packageName: 'localsend_app',
      appName: 'LocalSend',
      flatpakInfo: scope == null ? null : '[Application]\nname=org.localsend.localsend_app\n[Instance]\nhost-config-dir=${hostConfig ?? '${root.path}/host-config'}\n[Context]\nfilesystems=$scope;\n',
    );

    test('absolute XDG wins and invalid relative XDG falls back to HOME', () {
      expect(resolve().filePath, '${root.path}/config/autostart/localsend_app.desktop');
      expect(resolve(environment: {'HOME': root.path, 'XDG_CONFIG_HOME': 'relative'}).filePath, '${root.path}/.config/autostart/localsend_app.desktop');
      expect(resolve(environment: {'HOME': 'relative'}).snapshot().enabled, null);
    });

    test('native absence can be enabled atomically and disable absence is idempotent', () {
      final registration = resolve();
      expect(registration.snapshot().enabled, false);
      expect(registration.disable(), true);
      expect(registration.enable(hidden: true), true);
      expect(registration.snapshot().enabled, true);
      expect(registration.snapshot().hidden, true);
      expect(registration.disable(), true);
      expect(registration.disable(), true);
    });

    test('revoked scope hides stale private entry and rejects mutation', () {
      final registration = resolve(scope: 'xdg-download');
      final file = File(registration.filePath!);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(serializeLinuxAutoStartEntry('LocalSend', ['/opt/localsend']));
      expect(registration.snapshot().enabled, null);
      expect(registration.enable(hidden: false), false);
      expect(registration.disable(), false);
      expect(file.existsSync(), true);
    });

    test('exact scope modes expose registration while read-only refuses mutation', () {
      for (final mode in ['', ':create', ':rw', ':ro']) {
        final registration = resolve(scope: 'xdg-config/autostart$mode');
        Directory(File(registration.filePath!).parent.path).createSync(recursive: true);
        expect(registration.snapshot().enabled, false);
        expect(registration.snapshot().canModify, mode != ':ro');
        if (mode == ':ro') {
          final file = File(registration.filePath!);
          final contents = serializeLinuxAutoStartEntry('LocalSend', ['/usr/bin/flatpak', 'run', '--command=/app/localsend_app', 'org.localsend.localsend_app']);
          file.writeAsStringSync(contents);
          expect(registration.snapshot().enabled, true);
          expect(registration.enable(hidden: false), false);
          expect(registration.disable(), false);
          expect(file.readAsStringSync(), contents);
        }
      }
    });

    test('broad grants do not authenticate a private sandbox config directory', () {
      for (final scope in ['xdg-config', 'home', 'host']) {
        final registration = resolve(scope: scope);
        File(registration.filePath!).parent.createSync(recursive: true);
        expect(registration.snapshot().enabled, null);
        final sameConfig = resolve(scope: scope, hostConfig: '${root.path}/config');
        expect(sameConfig.snapshot().enabled, false);
      }
    });

    test('conflicting scope modes are unavailable even with an exposed directory', () {
      final registration = resolve(scope: 'xdg-config/autostart:ro;xdg-config/autostart:rw');
      File(registration.filePath!).parent.createSync(recursive: true);
      expect(registration.snapshot().enabled, null);
      expect(registration.disable(), false);
    });

    test('Flatpak serializes the host launcher, not the sandbox executable', () {
      final registration = resolve(scope: 'xdg-config/autostart:create');
      File(registration.filePath!).parent.createSync(recursive: true);
      expect(registration.enable(hidden: true), true);
      final contents = File(registration.filePath!).readAsStringSync();
      expect(parseLinuxAutoStartEntry(contents, ['/usr/bin/flatpak', 'run', '--command=/app/localsend_app', 'org.localsend.localsend_app'])?.hidden, true);
      expect(parseLinuxAutoStartEntry(contents, ['/opt/localsend']), null);
    });

    test('the old literal writer remains repairable for native spaces and Flatpak', () {
      for (final sandboxed in [false, true]) {
        final executable = sandboxed ? '/app/localsend_app' : '/opt/Local Send/localsend';
        final registration = LinuxAutoStart.resolve(
          environment: {'HOME': root.path, 'XDG_CONFIG_HOME': '${root.path}/config'},
          executable: executable,
          packageName: 'localsend_app',
          appName: 'LocalSend',
          flatpakInfo: sandboxed ? '[Application]\nname=org.localsend.localsend_app\n[Context]\nfilesystems=xdg-config/autostart:create;\n' : null,
        );
        final file = File(registration.filePath!);
        file.parent.createSync(recursive: true);
        // Exact previous writer template, independent of the new serializer.
        file.writeAsStringSync('''
[Desktop Entry]
Type=Application
Name=LocalSend
Comment=LocalSend startup script
Exec=$executable --hidden
StartupNotify=false
Terminal=false
''');
        final old = registration.snapshot();
        expect(old.enabled, false);
        expect(old.hidden, true);
        expect(old.canModify, true);
        expect(registration.enable(hidden: old.hidden), true);
        expect(registration.snapshot().enabled, true);
        expect(registration.snapshot().hidden, true);
      }
    });

    test('foreign commands cannot use legacy repair recognition', () {
      final registration = resolve(scope: 'xdg-config/autostart:create');
      final file = File(registration.filePath!);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('''
[Desktop Entry]
Type=Application
Name=LocalSend
Comment=LocalSend startup script
Exec=/app/foreign --hidden
StartupNotify=false
Terminal=false
''');
      expect(registration.snapshot().enabled, null);
      expect(registration.snapshot().canModify, false);
      expect(registration.enable(hidden: true), false);
    });
  });
}
