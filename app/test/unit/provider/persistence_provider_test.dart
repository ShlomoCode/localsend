import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/quick_save_mode.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final version in [3, null]) {
    for (final (storedValue, expectedMode) in [
      (true, QuickSaveMode.on),
      (false, QuickSaveMode.paired),
      ('off', QuickSaveMode.off),
    ]) {
      test('startup migrates quick save value $storedValue from storage version $version', () async {
        SharedPreferences.setMockInitialValues({
          'ls_version': ?version,
          'ls_quick_save': storedValue,
          'ls_locale': 'en',
          'ls_show_token': 'test-token',
          'ls_alias': 'Test device',
          'ls_security_context': '{}',
          'ls_color': 'localsend',
          'ls_https': false,
        });

        final persistence = await PersistenceService.initialize(supportsDynamicColors: false);
        final stored = await SharedPreferencesStorePlatform.instance.getAll();

        expect(persistence.isFirstAppStart, false);
        expect(persistence.getQuickSave(), expectedMode);
        expect(stored['flutter.ls_quick_save'], expectedMode.name);
        expect(stored['flutter.ls_version'], 4);
        expect(stored['flutter.ls_https'], false);
      });
    }
  }
}
