import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/main.dart';
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;
import 'form_responsiveness_test.dart' show CreationApi;

Future<void> chooseSupply(WidgetTester tester, String mode) async {
  final selector = find.byKey(const ValueKey('session-supply'));
  await tester.ensureVisible(selector);
  await tester.tap(selector);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('supply-option-$mode')).hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await (FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'))).load();
  });
  for (final language in ['es', 'en']) {
    testWidgets('Custom voltage rejects ranges and unsupported values in $language', (tester) async {
      SharedPreferences.setMockInitialValues({'circuitlab.language': language});
      final api = CreationApi();
      final strings = AppStrings(language);
      await tester.pumpWidget(ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)], child: const CircuitLabApp(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.t('newSession')));
      await tester.pumpAndSettle();
      for (final entry in {
        'sessionName': 'Custom voltage test', 'projectSetup': 'Declared sensor module',
        'whatShouldItDo': 'Observe the sensor response', 'whatIsHappening': 'No sensor response received',
      }.entries) {
        final field = find.widgetWithText(TextField, strings.t(entry.key));
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      await chooseSupply(tester, 'other');
      final voltage = find.widgetWithText(TextField, strings.t('supplyCustom'));
      final submit = find.text(strings.t('createSession'));
      for (final invalid in ['3.3 a 5 V', '0', '5.1']) {
        await tester.ensureVisible(voltage);
        await tester.enterText(voltage, invalid);
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(api.created, isNull);
        expect(find.text(strings.t('positiveSupplyRequired')), findsOneWidget);
      }
      await tester.ensureVisible(voltage);
      await tester.enterText(voltage, '2,5');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(api.created?['supply_v'], 2.5);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Mixed supplies keep their meaning and reuse the expected behavior in $language', (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'circuitlab.language': language});
      final api = CreationApi();
      final strings = AppStrings(language);
      final expected = List.filled(50, 'Observe the installed modules. ').join().trim();
      await tester.pumpWidget(ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)], child: const CircuitLabApp(),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.t('newSession')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, strings.t('supplyVoltageMaximum5V')), findsNothing);
      for (final entry in {
        'sessionName': 'Multi-module setup', 'projectSetup': 'UNO + DHT11 + RC522 + GPS',
        'whatShouldItDo': expected, 'whatIsHappening': 'GPS does not obtain a position',
      }.entries) {
        final field = find.widgetWithText(TextField, strings.t(entry.key));
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      await chooseSupply(tester, 'mixed');
      final submit = find.text(strings.t('createSession'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(api.created?['supply_v'], 5);
      expect(api.created?['setup'], contains(strings.t('supplyMixedDescription')));
      expect(api.created?['setup'], startsWith('UNO + DHT11 + RC522 + GPS'));
      expect(api.created!.containsKey('supply_mode'), isFalse);
      final prepare = find.text(strings.t('confirmSchematic'));
      await tester.ensureVisible(prepare);
      await tester.tap(prepare);
      await tester.pumpAndSettle();
      final behavior = find.widgetWithText(TextFormField, strings.t('functionalTestCondition'));
      expect(tester.widget<TextFormField>(behavior).controller!.text, expected);
      final input = find.descendant(of: behavior, matching: find.byType(TextField));
      expect(tester.widget<TextField>(input).maxLength, 2000);
      expect(find.text(strings.t('specificationExpectedLimitsHelp')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Common checks need no repeated names or units in $language', (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final strings = AppStrings(language);
      Map<String, dynamic>? saved;
      await tester.pumpWidget(shell(language, Builder(builder: (context) => Scaffold(
        body: TextButton(onPressed: () async {
          saved = await showDialog<Map<String, dynamic>>(context: context,
            builder: (_) => const SpecificationDialog(supplyVoltage: 5, specification: {
              'connections': ['Confirmed module connections'],
              'functional_description': 'Scan a card and observe current sensor data',
            }),
          );
        }, child: const Text('Open')),
      ))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (final preset in ['temperature', 'card', 'gps']) {
        final chip = find.byKey(ValueKey('preset-$preset'));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('TP1-unit'))).controller!.text, '°C');
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('TP1-min'))).controller!.text, isEmpty);
      for (final entry in {'min': '20', 'max': '30'}.entries) {
        final field = find.byKey(ValueKey('TP1-${entry.key}'));
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      final submit = find.text(strings.t('iConfirmTheSchematicAndCriteria'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final checks = saved!['points'] as List;
      expect(checks.map((point) => point['id']).toList(), ['TP1', 'TP2', 'TP3']);
      expect(checks.first['unit'], '°C');
      expect(checks.first['min_value'], 20);
      expect(checks.first['max_value'], 30);
      expect(checks[1]['kind'], 'reported_state');
      expect(checks[1]['expected_state'], true);
      expect(checks[2]['expected_state'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
