import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'evidence_specification_test.dart' show shell;

void main() {
  for (final language in ['es', 'en']) {
    test('Sensor values keep their own units and exact text in $language', () {
      final strings = AppStrings(language);
      expect(strings.observation(-2.5, '°C'), contains('°C'));
      expect(strings.observation('FIX', 'text'), 'FIX');
      expect(strings.criterion({'value_kind': 'number', 'unit': '%', 'min_value': 20, 'max_value': 80}), '20–80 %');
      expect(strings.criterion({'value_kind': 'text', 'expected_text': 'FIX'}), contains('FIX'));
    });
    testWidgets('Sensor criteria retain number, boolean and text at mobile width in $language', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? result;
      await tester.pumpWidget(shell(language, Builder(builder: (context) => TextButton(
        onPressed: () async => result = await showDialog<Map<String, dynamic>>(
          context: context, builder: (_) => const SpecificationDialog(
            supplyVoltage: 3.3, project: 'ESP32 + DHT11 + RFID + GPS',
            specification: {
              'connections': ['Confirmed fixture wiring'],
              'functional_description': 'Check declared sensor conditions',
              'points': [
                {'id': 'TP1', 'kind': 'numeric', 'label': 'Temperature', 'value_kind': 'number',
                  'unit': '°C', 'min_value': -10, 'max_value': 40},
                {'id': 'TP2', 'kind': 'text', 'label': 'GPS status', 'value_kind': 'text', 'expected_text': 'FIX'},
              ],
            },
          ),
        ), child: const Text('Open'),
      ))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('ESP32 + DHT11 + RFID + GPS'), findsOneWidget);
      final submit = find.text(AppStrings(language).t('iConfirmTheSchematicAndCriteria'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(result?['points'][0]['value_kind'], 'number');
      expect(result?['points'][0]['min_value'], -10);
      expect(result?['points'][0]['unit'], '°C');
      expect(result?['points'][1]['expected_text'], 'FIX');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
