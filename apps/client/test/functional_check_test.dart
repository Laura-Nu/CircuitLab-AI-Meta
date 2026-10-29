import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/functional_check.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

void main() {
  for (final language in ['en', 'es']) {
    for (final baseline in [false, true]) {
      testWidgets(
        'Functional test requires observation, explicit result and confirmation in $language, baseline=$baseline',
        (tester) async {
          tester.view.physicalSize = const Size(390, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          Map<String, dynamic>? result;
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('en'), Locale('es')],
              localizationsDelegates: const [
                AppStringsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => FunctionalCheckDialog(
                          baseline: baseline,
                          criteria:
                              'The LED must illuminate under the stated conditions.',
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              strings.t(
                baseline
                    ? 'baselineFunctionalConfirmed'
                    : 'functionalTestConfirmed',
              ),
            ),
            findsOneWidget,
          );
          final save = find.widgetWithText(
            FilledButton,
            strings.t('saveFunctionalTest'),
          );
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          await tester.enterText(
            find.byType(TextField),
            'Observed fixture: LED remained off.',
          );
          await tester.tap(find.byType(DropdownButtonFormField<bool>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('functionalTestFailed')).last);
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          await tester.ensureVisible(find.byType(CheckboxListTile));
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(result?['passed'], isFalse);
          expect(
            result?['observations'],
            'Observed fixture: LED remained off.',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
