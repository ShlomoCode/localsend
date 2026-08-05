import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/i18n.dart';
import 'package:test/test.dart';

void main() {
  group('i18n', () {
    test('Should compile', () {
      // The following test will fail if the i18n file is either not compiled
      // or there are compile-time errors.
      expect(AppLocale.en.translations.general.accept, 'Accept');
    });

    test('All locales should be supported by Flutter', () {
      for (final locale in AppLocale.values) {
        expect(kMaterialSupportedLanguages, contains(locale.languageCode));
      }
    });

    test('Hebrew remaining time uses the correct singular, dual, and plural forms', () async {
      await initI18n();
      final translations = AppLocale.he.translations;
      final remainingTime = translations.progressPage.remainingTime;

      expect(remainingTime.hours(h: 1, m: 1), '1 שעה ו-1 דקה');
      expect(remainingTime.hours(h: 2, m: 2), 'שעתיים ושתי דקות');
      expect(remainingTime.hours(h: 3, m: 3), '3 שעות ו-3 דקות');
      expect(remainingTime.days(d: 1, h: 2, m: 3), '1 יום, שעתיים ו-3 דקות');
      expect(remainingTime.days(d: 2, h: 1, m: 2), 'יומיים, 1 שעה ושתי דקות');
      expect(remainingTime.days(d: 3, h: 0, m: 1), '3 ימים, 0 שעות ו-1 דקה');
    });
  });
}
