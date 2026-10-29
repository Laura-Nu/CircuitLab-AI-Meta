import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'messages.g.dart';
import '../core/number_format.dart';

class AppStrings {
  final String language;
  const AppStrings(this.language);
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings)!;
  String t(String key, [Map<String, Object?> arguments = const {}]) {
    final template =
        localizedMessages[language]?[key] ?? localizedMessages['en']![key];
    if (template == null) throw ArgumentError('Unknown localization key: $key');
    return template.replaceAllMapped(RegExp(r'\{([a-zA-Z_]\w*)\}'), (m) {
      final value = arguments[m[1]];
      return value is num ? number(value) : '${value ?? m[0]}';
    });
  }

  String number(num value, {int? decimalPlaces}) =>
      formatNumber(value, language: language, decimalPlaces: decimalPlaces);

  String booleanValue(dynamic value) => value == null
      ? t('readingStillNeeded')
      : t(value == true ? 'booleanTrue' : 'booleanFalse');

  String observation(dynamic value, [dynamic unit = 'V']) => value == null
      ? t('readingStillNeeded')
      : unit == 'boolean'
      ? booleanValue(value)
      : '${number(value as num)} V';

  String criterion(Map point) =>
      point['value_kind'] == 'boolean' || point['unit'] == 'boolean'
      ? t('expectedBooleanState', {
          'state': booleanValue(point['expected_state']),
        })
      : '${number(point['min_v'] as num)}–${number(point['max_v'] as num)} V';

  String label(String code) =>
      localizedMessages[language]?.containsKey(code) == true ? t(code) : code;
}

class AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const AppStringsDelegate();
  @override
  bool isSupported(Locale locale) =>
      const ['en', 'es'].contains(locale.languageCode);
  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture(AppStrings(locale.languageCode));
  @override
  bool shouldReload(AppStringsDelegate old) => false;
}
