import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/diagnostic_summary.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

void main() {
  for (final language in ['es', 'en']) {
    for (final width in [320.0, 1440.0]) {
      testWidgets(
        'Current evidence and hypothesis details at $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          final session = {
            'id': 'fixture',
            'analysis_steps': 2,
            'pending_test': {
              'observations': ['Untranslated fallback'],
              'translations': {
                language: {
                  'observations': ['Visible observation'],
                },
              },
            },
            'hypotheses': [
              {
                'data': {'analysis_step': 1, 'cause': 'Obsolete cause'},
              },
              for (var i = 0; i < 2; i++)
                {
                  'data': {
                    'analysis_step': 2,
                    'cause': 'Cause $i',
                    'explanation': 'Explanation $i',
                    'status': i == 0 ? 'proposed' : 'contradicted',
                    'evidence_ids': ['private-technical-id'],
                  },
                },
            ],
          };
          Future<void> show({bool admin = false}) async {
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
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: DiagnosticSummary(
                      session: session,
                      technicalDetails: admin,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          await show();
          expect(find.text('Visible observation'), findsOneWidget);
          expect(find.text('Untranslated fallback'), findsNothing);
          expect(find.text('Obsolete cause'), findsNothing);
          expect(
            find.text(strings.t('hypothesesNotConclusions')),
            findsOneWidget,
          );
          expect(find.text('Explanation 0').hitTestable(), findsOneWidget);
          expect(find.text('Explanation 1').hitTestable(), findsNothing);
          expect(find.textContaining('private-technical-id'), findsNothing);
          await tester.ensureVisible(find.text('Cause 1'));
          await tester.tap(find.text('Cause 1'));
          await tester.pumpAndSettle();
          expect(find.text('Explanation 1').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await show(admin: true);
          expect(find.textContaining('private-technical-id'), findsWidgets);
        },
      );
    }
  }
}
