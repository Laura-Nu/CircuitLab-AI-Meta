import 'package:web/web.dart' as web;

String? takeRequestedLanguage() {
  final uri = Uri.base;
  final language = uri.queryParameters['lang'];
  if (!const ['es', 'en'].contains(language)) return null;
  final parameters = Map<String, String>.from(uri.queryParameters)
    ..remove('lang');
  final cleaned = uri.replace(
    query: parameters.isEmpty ? '' : Uri(queryParameters: parameters).query,
  );
  try {
    web.window.history.replaceState(null, '', cleaned.toString());
  } catch (_) {}
  return language;
}

void saveLandingLanguage(String language) {
  try {
    web.window.localStorage.setItem('circuitlab.language', language);
  } catch (_) {}
}

void updateDocumentLanguage(String language) {
  web.document.documentElement?.setAttribute('lang', language);
  web.document.title = language == 'en'
      ? 'CircuitLab AI · Laboratory'
      : 'CircuitLab AI · Laboratorio';
}
