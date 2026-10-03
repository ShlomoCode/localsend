import 'dart:io';

import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File desktopFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('localsend-autostart-');
    desktopFile = File('${tempDir.path}/autostart/localsend_app.desktop');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test(
    'writes an autostart entry with a quoted AppImage path and a separate hidden argument',
    () {
      writeLinuxAutoStartFile(
        desktopFile,
        appName: 'LocalSend',
        executable: r'/home/u/My App "`$%\AppImage',
        startHidden: true,
      );

      expect(
        desktopFile.readAsStringSync(),
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=LocalSend\n'
        'Comment=LocalSend startup script\n'
        r'Exec="/home/u/My App \\"\\`\\$%%\\\\AppImage" --hidden'
        '\nStartupNotify=false\n'
        'Terminal=false\n',
      );
    },
  );

  test('writes an autostart entry without the hidden argument', () {
    writeLinuxAutoStartFile(
      desktopFile,
      appName: 'LocalSend',
      executable: '/home/u/LocalSend.AppImage',
      startHidden: false,
    );

    expect(
      desktopFile.readAsStringSync(),
      contains('Exec="/home/u/LocalSend.AppImage"\n'),
    );
    expect(desktopFile.readAsStringSync(), isNot(contains(startHiddenFlag)));
  });

  test(
    'repairs only the temporary executable while retaining arguments and disabled metadata',
    () {
      const original =
          '[Desktop Entry]\n'
          'Name=My LocalSend\n'
          'Exec=/tmp/.mount_localSabc/localsend_app --hidden --custom=value\n'
          'Hidden=true\n'
          'X-GNOME-Autostart-enabled=false\n'
          '[Desktop Action Open]\n'
          'Exec=/tmp/.mount_other/localsend_app --action\n';
      desktopFile.createSync(recursive: true);
      desktopFile.writeAsStringSync(original);

      expect(
        repairLinuxAutoStartFile(desktopFile, '/home/u/My App.AppImage'),
        isTrue,
      );
      expect(
        desktopFile.readAsStringSync(),
        original.replaceFirst(
          'Exec=/tmp/.mount_localSabc/localsend_app',
          'Exec="/home/u/My App.AppImage"',
        ),
      );
      expect(
        repairLinuxAutoStartFile(desktopFile, '/home/u/My App.AppImage'),
        isFalse,
      );
    },
  );

  test('repairs a quoted temporary executable without adding hidden mode', () {
    desktopFile.createSync(recursive: true);
    desktopFile.writeAsStringSync(
      '[Desktop Entry]\nExec="/tmp/.mount_localSabc/localsend_app"\nTerminal=false\n',
    );

    expect(
      repairLinuxAutoStartFile(desktopFile, '/home/u/LocalSend.AppImage'),
      isTrue,
    );
    expect(
      desktopFile.readAsStringSync(),
      '[Desktop Entry]\nExec="/home/u/LocalSend.AppImage"\nTerminal=false\n',
    );
  });

  for (final oldExec in [
    'Exec="/home/u/temp files/.mount_localSabc/localsend_app" --hidden',
    'Exec=/home/u/temp/appimage_extracted_123abc/localsend_app --custom=value',
  ]) {
    test('repairs an AppImage temporary executable under a custom TMPDIR: $oldExec', () {
      final original = '[Desktop Entry]\nName=LocalSend\n$oldExec\nX-GNOME-Autostart-enabled=false\n';
      desktopFile.createSync(recursive: true);
      desktopFile.writeAsStringSync(original);

      expect(repairLinuxAutoStartFile(desktopFile, '/home/u/LocalSend.AppImage'), isTrue);
      expect(
        desktopFile.readAsStringSync(),
        original.replaceFirst(oldExec.substring(0, oldExec.indexOf(' --')), 'Exec="/home/u/LocalSend.AppImage"'),
      );
    });
  }

  test('leaves missing and unrelated autostart files untouched', () {
    expect(
      repairLinuxAutoStartFile(desktopFile, '/home/u/LocalSend.AppImage'),
      isFalse,
    );
    expect(desktopFile.existsSync(), isFalse);

    for (final customExec in ['Exec=/usr/bin/custom-localsend --hidden', 'Exec=/opt/localsend/localsend_app --hidden']) {
      final original = '[Desktop Entry]\n$customExec\n[Desktop Action Open]\nExec=/tmp/.mount_old/localsend_app\n';
      desktopFile.createSync(recursive: true);
      desktopFile.writeAsStringSync(original);

      expect(repairLinuxAutoStartFile(desktopFile, '/home/u/LocalSend.AppImage'), isFalse);
      expect(desktopFile.readAsStringSync(), original);
    }
  });
}
