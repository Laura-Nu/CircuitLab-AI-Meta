import 'package:web/web.dart' as web;

/// Same-tab document navigation does not need a Flutter platform plugin.
Future<bool> openPublicUrl(Uri url) async {
  if (url.scheme != 'https' && url.scheme != 'http') {
    throw ArgumentError.value(url, 'url', 'Expected an HTTP or HTTPS URL');
  }
  web.window.location.assign(url.toString());
  return true;
}
