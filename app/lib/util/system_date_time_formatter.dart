import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:system_date_time_format/system_date_time_format.dart';

// TODO: Revisit this plugin when https://github.com/dart-lang/i18n/issues/67 is fixed.
// intl currently uses US date/time patterns for unsupported regional locales
// such as en_IL. Before returning to DateFormat.yMd/jm, verify those locales
// and user-selected system formats, which locale data alone may not reflect.

/// Formats displayed dates and times using the device's regional preferences.
class SystemDateTimeFormatter {
  static String dateTime(BuildContext context, DateTime value) => '${date(context, value)} ${time(context, value)}';

  static String date(BuildContext context, DateTime value) {
    final pattern = SystemDateTimeFormat.of(context).datePattern;
    return (pattern == null ? DateFormat.yMd(_locale) : DateFormat(pattern, _locale)).format(value);
  }

  static String time(BuildContext context, DateTime value) {
    final pattern = SystemDateTimeFormat.of(context).timePattern;
    return (pattern == null ? DateFormat.jm(_locale) : DateFormat(_withoutSeconds(pattern), _locale)).format(value);
  }

  static String _withoutSeconds(String pattern) {
    // Some platforms include seconds in the system's short time pattern.
    final seconds = RegExp(r's+').firstMatch(pattern);
    if (seconds == null) return pattern;
    var start = seconds.start;
    if (start > 0 && ':., '.contains(pattern[start - 1])) start--;
    return pattern.replaceRange(start, seconds.end, '');
  }

  static String get _locale {
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale.toString();
    if (DateFormat.localeExists(deviceLocale)) return deviceLocale;
    final appLocale = LocaleSettings.currentLocale.languageTag;
    return DateFormat.localeExists(appLocale) ? appLocale : 'en';
  }
}
