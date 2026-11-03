import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/measurement_points.dart';
import 'package:circuitlab_client/features/observation_readout.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;

void main() {
  const temperature = {
    'kind': 'numeric', 'value_kind': 'number', 'unit': '°C',
    'min_value': -5, 'max_value': 40,
  };
  const flag = {
    'kind': 'reported_state', 'value_kind': 'boolean', 'expected_state': false,
  };
  test('Criteria comparison respects units, boundaries, zero, false and exact text', () {
    expect(observationMatchesCriterion(temperature, -5, '°C'), isTrue);
    expect(observationMatchesCriterion(temperature, 0, '°C'), isTrue);
    expect(observationMatchesCriterion(temperature, 40, '°C'), isTrue);
    expect(observationMatchesCriterion(temperature, 41, '°C'), isFalse);
    expect(observationMatchesCriterion(temperature, 5, 'V'), isNull);
    expect(observationMatchesCriterion(temperature, double.nan, '°C'), isNull);
    expect(observationMatchesCriterion(flag, false, 'boolean'), isTrue);
    expect(observationMatchesCriterion(flag, 0, 'boolean'), isNull);
    expect(observationMatchesCriterion({'min_v': 3, 'max_v': 3.5}, 3300, 'mV'), isTrue);
    expect(observationMatchesCriterion({'min_v': 3, 'max_v': 3.5}, 3300, 'V'), isFalse);
    expect(observationMatchesCriterion({'value_kind': 'text', 'expected_text': '001A'}, '001A', 'text'), isTrue);
    expect(observationMatchesCriterion({'value_kind': 'text', 'expected_text': '001A'}, '001a', 'text'), isFalse);
    expect(observationMatchesCriterion({}, 5, 'V'), isNull);
  });

  for (final language in ['es', 'en']) {
    test('Reported boolean uses yes/no while pin state keeps HIGH/LOW in $language', () {
      final strings = AppStrings(language);
      expect(strings.pointObservation(flag, false, 'boolean'), strings.t('observationNo'));
      expect(strings.criterion(flag), contains(strings.t('observationNo')));
      expect(strings.pointObservation({'kind': 'digital_state'}, false, 'boolean'), strings.t('booleanFalse'));
    });
    for (final width in [320.0, 1440.0]) {
      testWidgets('Live, stale and invalid values stay distinct at $width in $language', (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = AppStrings(language);
        Future<void> render(Map sample, {bool live = true, Map point = temperature}) async {
          await tester.pumpWidget(shell(language, Scaffold(body: SingleChildScrollView(
            child: MediaQuery(
              data: MediaQueryData(size: Size(width, 1200), textScaler: const TextScaler.linear(1.6)),
              child: Padding(padding: const EdgeInsets.all(16), child: ObservationReadout(
                title: 'DHT11 · Temperature', observation: sample, point: point, live: live,
                now: DateTime.fromMillisecondsSinceEpoch(100000),
              )),
            ),
          ))));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        final sample = {
          'channel': 'dht11.temperature', 'value': -2.5, 'unit': '°C',
          'sensor': 'DHT11', 'received_at': 99,
        };
        await render(sample);
        expect(find.text(strings.observation(-2.5, '°C')), findsOneWidget);
        expect(find.text(strings.t('observationWithinCriterion')), findsOneWidget);
        expect(find.textContaining(strings.t('observationAge', {'seconds': 1})), findsOneWidget);
        await render({...sample, 'received_at': 90});
        expect(find.text(strings.t('observationWithinCriterion')), findsOneWidget);
        await render({...sample, 'received_at': 89});
        expect(find.text(strings.t('observationStale')), findsOneWidget);
        expect(find.text(strings.t('observationWithinCriterion')), findsNothing);
        await render({...sample, 'invalid': true});
        expect(find.text(strings.t('observationUnavailable')), findsOneWidget);
        expect(find.text(strings.observation(-2.5, '°C')), findsNothing);
        await render({...sample, 'unit': 'V'});
        expect(find.text(strings.t('observationUnitMismatch')), findsOneWidget);
        expect(find.text(strings.t('observationWithinCriterion')), findsNothing);
        await render({...sample, 'source': 'serial_reported'}, live: false);
        expect(find.textContaining(strings.t('observationAge', {'seconds': 1})), findsNothing);
        expect(find.text(strings.label('serial_reported')), findsOneWidget);
        await render({'channel': 'gps.fix', 'value': false, 'unit': 'boolean', 'received_at': 99}, point: flag);
        expect(find.text(strings.t('observationNo')), findsOneWidget);
        expect(find.text(strings.t('observationWithinCriterion')), findsOneWidget);
        await render(sample, point: {});
        expect(find.text(strings.t('observationNotLinked')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
