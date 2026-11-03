import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/session_guidance.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

void main() {
  for (final language in ['es', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('Guided actions and honest closure at $width in $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = AppStrings(language);
        var manual = 0;
        var baseline = 0;
        var programs = 0;
        final session = <String, dynamic>{
          'state': 'awaiting_measurement',
          'can_edit': true,
          'analysis_steps': 1,
          'pending_test': {
            'point_id': 'TP2',
            'instruction': 'Read the authorized supply point.',
            'rationale': 'Untranslated rationale',
            'translations': {
              language: {'rationale': 'Reason for the selected observation'},
            },
          },
          'specification': {},
          'completion': {},
          'verifications': [],
        };
        Future<void> show() async {
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
                  child: SessionGuidance(
                    session: session,
                    busy: false,
                    onSpec: () {},
                    onProgram: () => programs++,
                    onEvidence: () {},
                    onAnalyze: () {},
                    onConfirm: () {},
                    onManual: () => manual++,
                    onBridge: () {},
                    onIntervention: () {},
                    onFunctional: () {},
                    onVerify: () {},
                    onBaseline: () => baseline++,
                    onReport: () {},
                    onNew: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await show();
        expect(find.text(strings.t('yourTurnMeasurement')), findsOneWidget);
        expect(
          find.text(strings.t('requestedPointGuide', {'point': 'TP2'})),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.text(strings.t('recordMeasurement')));
        expect(manual, 1);
        await tester.ensureVisible(find.text(strings.t('whyThisStep')));
        await tester.tap(find.text(strings.t('whyThisStep')));
        await tester.pumpAndSettle();
        expect(find.text('Reason for the selected observation').hitTestable(), findsOneWidget);
        expect(find.text('Untranslated rationale'), findsNothing);
        session['specification'] = {'points': [
          {'id': 'TP2', 'label': 'Humidity available', 'kind': 'reported_state',
            'value_kind': 'boolean', 'expected_state': true},
        ]};
        await show();
        expect(find.text(strings.t('requestedObservationGuide', {'point': 'Humidity available'})), findsOneWidget);
        expect(find.text(strings.t('requestedPointGuide', {'point': 'Humidity available'})), findsNothing);
        session['state'] = 'awaiting_evidence';
        session['pending_test'] = {'action': 'request_program', 'instruction': 'Attach the loaded code.'};
        await show();
        await tester.ensureVisible(find.text(strings.t('attachProgram')));
        await tester.tap(find.text(strings.t('attachProgram')));
        expect(programs, 1);
        session['state'] = 'awaiting_functional_check';
        session['completion'] = {'baseline_available': true};
        await show();
        await tester.ensureVisible(
          find.text(strings.t('checkFunctionAndFinish')),
        );
        await tester.tap(find.text(strings.t('checkFunctionAndFinish')));
        expect(baseline, 1);
        session['state'] = 'no_fault_found';
        session['completion'] = {'terminal': true};
        await show();
        expect(find.text(strings.t('finishedNoFault')), findsOneWidget);
        expect(find.text(strings.t('checkFunctionAndFinish')), findsNothing);
        expect(find.text(strings.t('readableReport')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
        session['state'] = 'inconclusive';
        session['pending_test'] = {'instruction': 'Review the DHT pin and attach the actual program.'};
        await show();
        expect(find.text('Review the DHT pin and attach the actual program.'), findsOneWidget);
        session['verifications'] = [{'data': {'functional_check': {
          'passed': false, 'observations': 'Record cancelled after DHT error',
        }}}];
        await show();
        expect(find.text('Record cancelled after DHT error'), findsOneWidget);
        expect(find.text(strings.t('failedFunctionFollowUpHelp')), findsOneWidget);
        session['state'] = 'awaiting_measurement';
        session['can_edit'] = false;
        await show();
        expect(find.text(strings.t('readerWaitingOwner')), findsOneWidget);
        expect(find.text(strings.t('recordMeasurement')), findsNothing);
      });
    }
  }
}
