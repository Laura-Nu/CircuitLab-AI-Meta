import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'messages.g.dart';

class AppStrings {
  final String language;
  const AppStrings(this.language);
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings)!;
  String t(String key, [Map<String, Object?> arguments = const {}]) {
    final template =
        localizedMessages[language]?[key] ?? localizedMessages['en']![key];
    if (template == null) throw ArgumentError('Unknown localization key: $key');
    return template.replaceAllMapped(
      RegExp(r'\{([a-zA-Z_]\w*)\}'),
      (m) => '${arguments[m[1]] ?? m[0]}',
    );
  }

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
