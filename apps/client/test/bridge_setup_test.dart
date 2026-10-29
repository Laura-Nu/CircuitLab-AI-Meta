import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/bridge_setup.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;

void main() {
  for (final language in ['en', 'es']) {
    for (final width in [320.0, 768.0, 1440.0]) {
      for (final supported in [true, false]) {
        testWidgets(
          'Browser USB guidance at $width in $language, supported=$supported',
          (tester) async {
            tester.view.physicalSize = Size(width, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final strings = AppStrings(language);
            await tester.pumpWidget(
              shell(
                language,
                Scaffold(
                  body: SingleChildScrollView(
                    child: BridgeSetupCard(supported: supported),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.text(
                strings.t(supported ? 'usbSetupIntro' : 'usbUnsupported'),
              ),
              findsOneWidget,
            );
            expect(find.text(strings.t('usbSetupSteps')), findsOneWidget);
            expect(find.byType(FilledButton), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  for (final language in ['en', 'es']) {
    testWidgets(
      'Inline port-opening and failure feedback stays readable at 320 px in $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = AppStrings(language);
        for (final key in [
          'usbChoosingPort',
          'usbOpeningPort',
          'usbStartingInstrument',
          'usbOpenTimeout',
          'usbCancelled',
        ]) {
          final busy = !['usbOpenTimeout', 'usbCancelled'].contains(key);
          await tester.pumpWidget(
            shell(
              language,
              Scaffold(
                body: SingleChildScrollView(
                  child: UsbConnectionStatus(
                    message: strings.t(key),
                    busy: busy,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text(strings.t(key)), findsOneWidget);
          expect(
            find.byType(CircularProgressIndicator),
            busy ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
