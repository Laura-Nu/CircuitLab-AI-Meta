import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/bridge_setup.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;

void main() {
  test('Bridge credential targets the same API host and prefix', () {
    expect(
      bridgeSocketUri(Uri.parse('https://example.test/api/v1/')).toString(),
      'wss://example.test/api/v1/devices/connect',
    );
    expect(
      bridgeSocketUri(Uri.parse('http://localhost:8000/api/v1')).toString(),
      'ws://localhost:8000/api/v1/devices/connect',
    );
    expect(bridgeDownloadPath, '/downloads/circuitlab-bridge-windows.exe');
  });
  for (final language in ['en', 'es']) {
    for (final width in [320.0, 768.0, 1440.0]) {
      testWidgets(
        'Bridge download and existing-install instructions fit $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var downloads = 0;
          final strings = AppStrings(language);
          await tester.pumpWidget(
            shell(
              language,
              Scaffold(
                body: SingleChildScrollView(
                  child: BridgeSetupCard(onDownload: () => downloads++),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(strings.t('bridgeInstallHint')), findsOneWidget);
          expect(find.text(strings.t('bridgeSetupSession')), findsOneWidget);
          final button = find.byKey(const ValueKey('download-windows-bridge'));
          await tester.ensureVisible(button);
          await tester.tap(button);
          expect(downloads, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
