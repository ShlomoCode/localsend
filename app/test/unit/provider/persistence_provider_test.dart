import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/quick_save_mode.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (storedValue, expectedMode) in [
    (true, QuickSaveMode.on),
    (false, QuickSaveMode.paired),
    ('off', QuickSaveMode.off),
  ]) {
    test('startup reads quick save value $storedValue', () async {
      SharedPreferences.setMockInitialValues({
        'ls_version': 3,
        'ls_quick_save': storedValue,
        'ls_locale': 'en',
        'ls_show_token': 'test-token',
        'ls_alias': 'Test device',
        'ls_security_context': '{}',
        'ls_color': 'localsend',
      });

      final persistence = await PersistenceService.initialize(supportsDynamicColors: false);

      expect(persistence.getQuickSave(), expectedMode);
    });
  }
}
