import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/usb_serial.dart';
import 'package:circuitlab_client/core/measurement_points.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'package:circuitlab_client/features/serial_monitor.dart';
import 'evidence_specification_test.dart' show shell, specification;

class FixtureSerialPort extends UsbSerialPort {
  bool active = false;
  @override
  bool get supported => true;
  @override
  Future<Map<String, dynamic>> connectMonitor(int baudRate) async {
    active = true;
    return {'status': 'connected'};
  }
  @override
  Map<String, dynamic> monitorSnapshot() => {
    'connected': active, 'sequence': 1, 'dropped': 0,
    'lines': ['DHT11 temperature=23.5 C humidity=48 %', 'RFID UID=${'AB' * 200}', 'GPS fix=false'],
  };
  @override
  Future<void> disconnect() async { active = false; }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
  });
  test('Program Yes/No stays separate from an instrument GPIO state', () {
    expect(instrumentSupportsObservation({'value_kind': 'boolean', 'kind': 'reported_state'}), isFalse);
    expect(instrumentSupportsObservation({'value_kind': 'boolean', 'kind': 'digital_state'}), isTrue);
    expect(instrumentSupportsObservation({'value_kind': 'number', 'unit': '°C'}), isFalse);
    expect(instrumentSupportsObservation({'min_v': 0, 'max_v': 5}), isTrue);
  });
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
  for (final language in ['es', 'en']) {
    testWidgets('New check explicitly chooses its type without assuming volts in $language', (tester) async {
      final strings = AppStrings(language);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(shell(language, Builder(builder: (context) => TextButton(
        onPressed: () async => saved = await showDialog<Map<String, dynamic>>(
          context: context, builder: (_) => const SpecificationDialog(
            supplyVoltage: 3.3,
            specification: {'connections': ['Confirmed synthetic wiring'],
              'functional_description': 'Observe the actual project condition'},
          ),
        ), child: const Text('Open'),
      ))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final selector = find.byKey(const ValueKey('TP1-kind'));
      expect(tester.widget<DropdownButtonFormField<String>>(selector).initialValue, isNull);
      expect(find.byKey(const ValueKey('TP1-min')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('TP1-label')), 'GPS valid fix');
      Future<void> choose(String message) async {
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.t(message)).last);
        await tester.pumpAndSettle();
      }
      await choose('measurementKindNumber');
      expect(find.byKey(const ValueKey('TP1-unit')), findsOneWidget);
      final minimumInput = find.descendant(
        of: find.byKey(const ValueKey('TP1-min')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(minimumInput).keyboardType.signed, isTrue);
      await choose('measurementKindText');
      expect(find.byKey(const ValueKey('TP1-expected-text')), findsOneWidget);
      expect(find.byKey(const ValueKey('TP1-min')), findsNothing);
      await choose('observationVoltageType');
      expect(find.byKey(const ValueKey('TP1-min')), findsOneWidget);
      expect(find.byKey(const ValueKey('TP1-unit')), findsNothing);
      await choose('measurementKindReportedState');
      expect(find.byKey(const ValueKey('TP1-min')), findsNothing);
      final state = find.byKey(const ValueKey('TP1-expected-state'));
      await tester.ensureVisible(state);
      await tester.tap(state);
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.t('observationNo')).last);
      await tester.pumpAndSettle();
      final submit = find.text(strings.t('iConfirmTheSchematicAndCriteria'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final point = (saved!['points'] as List).single as Map;
      expect(point['kind'], 'reported_state');
      expect(point['value_kind'], 'boolean');
      expect(point['expected_state'], false);
      expect(point.containsKey('min_v'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    for (final layout in [
      (width: 320.0, height: 900.0, scale: 2.0, keyboard: 260.0),
      (width: 568.0, height: 320.0, scale: 1.5, keyboard: 100.0),
      (width: 768.0, height: 1024.0, scale: 2.0, keyboard: 280.0),
      (width: 1440.0, height: 900.0, scale: 1.5, keyboard: 0.0),
    ]) {
      testWidgets('Mixed module criteria and serial monitor at $layout in $language', (tester) async {
        tester.view.physicalSize = Size(layout.width, layout.height);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = layout.scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final strings = AppStrings(language);
        Map<String, dynamic>? saved;
        await tester.pumpWidget(shell(language, Scaffold(body: TextButton(
          child: const Text('Open'),
          onPressed: () async {
            final context = tester.element(find.text('Open'));
            saved = await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (_) => const SpecificationDialog(
                supplyVoltage: 3.3,
                project: 'ESP32 + temperature/humidity sensor + RFID + GPS + other modules',
                specification: {
                  'connections': ['Confirmed fixture connections and individual module supplies'],
                  'functional_description': 'Check every declared sensor under its operating condition',
                  'points': [
                    {'id': 'TP1', 'kind': 'numeric', 'value_kind': 'number', 'label': 'Temperature of the external sensor',
                      'unit': '°C', 'min_value': -10, 'max_value': 40},
                    {'id': 'TP2', 'kind': 'text', 'value_kind': 'text', 'label': 'RFID reader identifier', 'expected_text': 'AB12CD34'},
                    {'id': 'TP3', 'kind': 'digital_state', 'value_kind': 'boolean', 'label': 'GPS valid fix', 'expected_state': false},
                    {'id': 'TP4', 'kind': 'supply', 'label': 'Module supply measured relative to common ground', 'min_v': 3.2, 'max_v': 3.3},
                  ],
                },
              ),
            );
          },
        ))));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
        await tester.pumpAndSettle();
        final minimum = find.byKey(const ValueKey('TP1-min'));
        final maximum = find.byKey(const ValueKey('TP1-max'));
        await tester.ensureVisible(minimum);
        await tester.enterText(minimum, '-5.5');
        await tester.ensureVisible(maximum);
        await tester.enterText(maximum, '42');
        if (layout.width <= 768) {
          expect(tester.getTopLeft(maximum).dy, greaterThan(tester.getTopLeft(minimum).dy));
        }
        final text = find.byKey(const ValueKey('TP2-expected-text'));
        await tester.ensureVisible(text);
        await tester.enterText(text, 'AB12CD34');
        final submit = find.text(strings.t('iConfirmTheSchematicAndCriteria'));
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(saved?['points'].length, 4);
        expect(saved?['points'][0]['min_value'], -5.5);
        expect(saved?['points'][1]['expected_text'], 'AB12CD34');
        expect(saved?['points'][2]['expected_state'], false);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        final api = CircuitApi()..access = 'isolated-ui-fixture';
        final serial = FixtureSerialPort();
        await tester.pumpWidget(shell(language, Scaffold(body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SerialMonitor(api: api, sessionId: 'isolated-ui-fixture', canSave: true,
            onSaved: () async {}, serial: serial),
        ))));
        await tester.tap(find.text(strings.t('serialMonitorTitle')));
        await tester.pumpAndSettle();
        final connect = find.widgetWithText(OutlinedButton, strings.t('serialConnect'));
        await tester.ensureVisible(connect);
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(serial.active, isTrue);
        final save = find.widgetWithText(FilledButton, strings.t('serialSave'));
        await tester.ensureVisible(save);
        expect(tester.getSize(save).width, lessThanOrEqualTo(layout.width));
        expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.dispose();
      });
    }
    testWidgets('Full 32-observation project remains editable in $language', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(shell(language, SpecificationDialog(
        supplyVoltage: 5, specification: specification(32),
      )));
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('add-test-point'));
      await tester.ensureVisible(add);
      expect(tester.widget<OutlinedButton>(add).onPressed, isNull);
      final last = find.byKey(const ValueKey('TP32-max'));
      await tester.ensureVisible(last);
      await tester.enterText(last, '4.9');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
