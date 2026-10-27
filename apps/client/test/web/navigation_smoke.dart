// Browser regression entrypoint, compiled and run by scripts/verify_web_navigation.py.
import 'package:web/web.dart' as web;
import 'package:circuitlab_client/core/public_navigation_web.dart';
import 'package:circuitlab_client/core/site_location.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  try {
    final original = Uri.parse(web.window.location.href);
    for (final language in ['es', 'en']) {
      final target = landingUri(language);
      check(target.origin == original.origin, 'Homepage origin changed');
      check(
        target.path == (language == 'en' ? '/en/' : '/'),
        'Homepage language is incorrect',
      );
      check(
        !target.hasQuery && !target.hasFragment,
        'Homepage retained application parameters',
      );
    }
    var rejected = false;
    try {
      await openPublicUrl(Uri.parse('javascript:alert(1)'));
    } on ArgumentError {
      rejected = true;
    }
    check(rejected, 'Non-web scheme was accepted');
    // Same-document navigation exercises the real browser without unloading this test page.
    check(
      await openPublicUrl(
        original.replace(fragment: 'circuitlab-navigation-check'),
      ),
      'Navigation failed',
    );
    check(
      web.window.location.hash == '#circuitlab-navigation-check',
      'Current tab did not navigate',
    );
    web.document.body!.setAttribute('data-result', 'passed');
    web.document.body!.textContent =
        'PASS: same-tab browser navigation, bilingual homepages, rejected unsafe schemes';
  } catch (error) {
    web.document.body!.setAttribute('data-result', 'failed');
    web.document.body!.textContent = 'FAIL: $error';
  }
}
