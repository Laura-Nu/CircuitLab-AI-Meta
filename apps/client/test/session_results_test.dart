import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/number_format.dart';
import 'package:circuitlab_client/features/session_results.dart';
import 'package:circuitlab_client/features/hardware_point_field.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;

void main() {
  test('Number display removes padding without losing small measurements', () {
    expect(formatNumber(5.0), '5');
    expect(formatNumber(2.500), '2.5');
    expect(formatNumber(.0004), '0.0004');
    expect(formatNumber(5.0004), '5.0004');
    expect(formatNumber(-0.0), '0');
    expect(formatNumber(5.0, decimalPlaces: 3), '5');
    expect(formatNumber(2.5, language: 'es'), '2,5');
    expect(formatNumber(.0004, language: 'es'), '0,0004');
    expect(
      AppStrings(
        'es',
      ).t('namedPointCriterion', {'name': 'Input', 'min': 0.0, 'max': 5.0}),
      contains('0–5'),
    );
  });
  for (final language in ['en', 'es']) {
    for (final width in [320.0, 1440.0]) {
      testWidgets('Persisted USB results and report at $width in $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = AppStrings(language);
        final session = <String, dynamic>{
          'measurements': <dynamic>[],
          'specification': {
            'points': [
              {'id': 'TP1', 'label': 'Supply'},
            ],
          },
        };
        var reports = 0;
        Future<void> render(List events) async {
          await tester.pumpWidget(
            shell(
              language,
              Scaffold(
                body: SingleChildScrollView(
                  child: SessionResults(
                    session: session,
                    events: events,
                    busy: false,
                    onReport: () => reports++,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
        }

        final request = {
          'kind': 'hardware_requested',
          'data': {'command_id': 'new'},
        };
        await render([]);
        expect(find.text(strings.t('usbNoReadingYet')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('viewSessionReport')));
        expect(reports, 1);
        await render([request]);
        expect(
          find.text(strings.t('hardwareWaitingForResult')),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await render([
          {
            'kind': 'hardware_result',
            'data': {'command_id': 'old', 'status': 'ok'},
          },
          request,
        ]);
        expect(
          find.text(strings.t('hardwareWaitingForResult')),
          findsOneWidget,
        );
        expect(find.text(strings.t('hardwareReadSaved')), findsNothing);
        await render([
          request,
          {
            'kind': 'hardware_failed',
            'data': {'command_id': 'new', 'status': 'timeout'},
          },
        ]);
        expect(
          find.text(
            strings.t('hardwareReadFailed', {
              'reason': strings.label('timeout'),
            }),
          ),
          findsOneWidget,
        );
        expect(find.text(strings.t('hardwareReadSaved')), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        session['measurements'] = [
          {
            'point_id': 'TP1',
            'value': 5.0,
            'source': 'simulated',
            'measured_at': 3,
          },
          {
            'point_id': 'TP1',
            'value': 2.5,
            'source': 'manual',
            'measured_at': 1,
          },
        ];
        await render([
          request,
          {
            'kind': 'hardware_result',
            'data': {'command_id': 'new', 'status': 'ok'},
          },
        ]);
        expect(
          find.text(
            strings.t('latestRecordedReading', {
              'point': 'Supply',
              'value': '5 V',
              'source': strings.label('simulated'),
            }),
          ),
          findsOneWidget,
        );
        expect(find.text(strings.t('hardwareReadSaved')), findsOneWidget);
        expect(find.textContaining('5.000'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets(
        'Requested point stays locked and channel is explained at $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          final points = [
            {'id': 'TP1', 'label': 'Alimentación'},
            {'id': 'TP2', 'label': 'Señal'},
          ];
          String value = 'TP1';
          await tester.pumpWidget(
            shell(
              language,
              Scaffold(
                body: SingleChildScrollView(
                  child: HardwarePointField(
                    specification: {'points': points},
                    points: points,
                    value: value,
                    locked: true,
                    onChanged: (v) => value = v,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Alimentación'), findsOneWidget);
          expect(find.byType(DropdownButtonFormField<String>), findsNothing);
          expect(
            find.text(strings.t('requestedHardwarePointHelp')),
            findsOneWidget,
          );
          expect(find.textContaining('A0'), findsOneWidget);
          expect(value, 'TP1');
          await tester.pumpWidget(
            shell(
              language,
              Scaffold(
                body: SingleChildScrollView(
                  child: StatefulBuilder(
                    builder: (context, update) => HardwarePointField(
                      specification: {'points': points},
                      points: points,
                      value: value,
                      locked: false,
                      onChanged: (v) => update(() => value = v),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Señal').last);
          await tester.pumpAndSettle();
          expect(value, 'TP2');
          expect(find.textContaining('A1'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
