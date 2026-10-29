import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/main.dart';
import 'package:circuitlab_client/core/measurement_points.dart';
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;
import 'layout_test.dart' show TestApi;

Map<String, dynamic> fixtureSpec() => {
  'connections': ['UI FIXTURE: declared supply and sensor terminal'],
  'functional_description':
      'UI FIXTURE: sensor output remains within the declared range.',
  'points': [
    {'id': 'TP2', 'label': 'Declared supply', 'min_v': 3.2, 'max_v': 3.3},
    {
      'id': 'TP7',
      'label': 'Declared sensor terminal',
      'kind': 'sensor_signal',
      'min_v': .2,
      'max_v': 2.8,
    },
  ],
};

void main() {
  test(
    'Names fall back safely and duplicate names retain distinct references',
    () {
      final spec = fixtureSpec();
      expect(measurementPointName(spec, 'TP7'), 'Declared sensor terminal');
      expect(
        measurementPointName(spec, 'TP7', includeReference: true),
        'Declared sensor terminal (TP7)',
      );
      expect(measurementPointName(spec, 'TP9'), 'TP9');
      (spec['points'] as List)[0]['label'] = 'Declared sensor terminal';
      expect(
        measurementPointName(spec, 'TP2'),
        'Declared sensor terminal (TP2)',
      );
      expect(
        measurementPointName(spec, 'TP7'),
        'Declared sensor terminal (TP7)',
      );
    },
  );
  for (final language in ['en', 'es']) {
    for (final width in [320.0, 1440.0]) {
      testWidgets(
        'Connection selection preserves pin name, ranges and stable IDs at $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          Map<String, dynamic>? saved;
          await tester.pumpWidget(
            shell(
              language,
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      saved = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => SpecificationDialog(
                          specification: fixtureSpec(),
                          supplyVoltage: 3.3,
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
            find.text(strings.t('specificationWiringTitle')),
            findsOneWidget,
          );
          expect(
            find.text(strings.t('specificationOperationTitle')),
            findsOneWidget,
          );
          expect(
            find.text(strings.t('specificationLocationsTitle')),
            findsOneWidget,
          );
          final example = find.byKey(const ValueKey('specification-example'));
          await tester.ensureVisible(example);
          await tester.tap(find.text(strings.t('specificationExampleTitle')));
          await tester.pumpAndSettle();
          expect(
            find.text(strings.t('specificationExampleLocations')),
            findsOneWidget,
          );
          await tester.tap(find.text(strings.t('specificationExampleTitle')));
          await tester.pumpAndSettle();
          final selector = find.byKey(const ValueKey('TP7-kind'));
          await tester.ensureVisible(selector);
          await tester.tap(selector);
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('observationVoltageType')).last);
          await tester.pumpAndSettle();
          for (final entry in {
            'label': 'Declared sensor terminal',
            'min': '0.2',
            'max': '2.8',
          }.entries) {
            expect(
              tester
                  .widget<TextFormField>(
                    find.byKey(ValueKey('TP7-${entry.key}')),
                  )
                  .controller!
                  .text,
              entry.value,
            );
          }
          await tester.tap(
            find.text(strings.t('iConfirmTheSchematicAndCriteria')),
          );
          await tester.pumpAndSettle();
          final point = (saved!['points'] as List).singleWhere(
            (p) => p['id'] == 'TP7',
          );
          expect(saved!['connections'], fixtureSpec()['connections']);
          expect(
            saved!['functional_description'],
            fixtureSpec()['functional_description'],
          );
          expect(point['kind'], 'sensor_signal');
          expect(point['label'], 'Declared sensor terminal');
          expect(point['min_v'], .2);
          expect(point['max_v'], 2.8);
          expect(tester.takeException(), isNull);
          // Reopening persisted data restores the selector without guessing a board pinout.
          await tester.pumpWidget(
            shell(
              language,
              SpecificationDialog(specification: saved!, supplyVoltage: 3.3),
            ),
          );
          expect(
            tester
                .widget<DropdownButtonFormField<String>>(
                  find.byKey(const ValueKey('TP7-kind')),
                )
                .initialValue,
            'custom',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'A named requested connection submits its original ID at $width in $language',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'circuitlab.language': language,
          });
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          final session = <String, dynamic>{
            'id': 'test-session',
            'title': 'Named connection fixture',
            'family': 'analog_sensor',
            'supply_v': 3.3,
            'state': 'awaiting_measurement',
            'version': 5,
            'spec_version': 1,
            'analysis_steps': 1,
            'can_edit': true,
            'expected': 'Stable sensor output',
            'symptoms': 'Signal needs checking',
            'pending_test': {
              'action': 'read_voltage',
              'point_id': 'TP7',
              'instruction': 'Read the confirmed sensor terminal.',
            },
            'specification': fixtureSpec(),
            'jobs': [],
            'measurements': [],
            'evidence': [],
            'hypotheses': [],
            'verifications': [],
            'interventions': [],
          };
          final api = TestApi(authenticated: true, fixture: session);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [apiProvider.overrideWithValue(api)],
              child: const CircuitLabApp(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Named connection fixture'));
          await tester.tap(find.text('Named connection fixture'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              strings.t('requestedPointGuide', {
                'point': 'Declared sensor terminal',
              }),
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(find.text(strings.t('recordMeasurement')));
          await tester.tap(find.text(strings.t('recordMeasurement')));
          await tester.pumpAndSettle();
          expect(find.text('Declared sensor terminal'), findsWidgets);
          final field = find.widgetWithText(
            TextField,
            strings.t('readingInV05'),
          );
          await tester.ensureVisible(field);
          await tester.enterText(field, '1.5');
          await tester.ensureVisible(find.byType(CheckboxListTile));
          await tester.tap(find.byType(CheckboxListTile));
          await tester.tap(find.text(strings.t('saveReading')));
          await tester.pumpAndSettle();
          expect(api.recorded?['point_id'], 'TP7');
          expect(api.recorded?['value'], 1.5);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
