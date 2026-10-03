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
}
