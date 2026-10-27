Uri landingUri(String language) {
  const origin = String.fromEnvironment(
    'SITE_ORIGIN',
    defaultValue: 'https://circuitlab.doc-ia.cloud',
  );
  final base = Uri.base.scheme.startsWith('http')
      ? Uri.base
      : Uri.parse(origin);
  return base.resolve(language == 'en' ? '/en/' : '/');
}
