import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/main.dart';
import 'package:circuitlab_client/core/form_fields.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'package:circuitlab_client/features/accounts.dart';
import 'package:circuitlab_client/features/functional_check.dart';
import 'accounts_test.dart' show AccountApi;
import 'layout_test.dart' show TestApi;
import 'evidence_specification_test.dart' show shell, specification;

class CreationApi extends TestApi {
  Map<String, dynamic>? created, detail;
  CreationApi() : super(authenticated: true);
  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    if (method == 'POST' && path == '/sessions') {
      created = Map<String, dynamic>.from(data);
      detail = {
        ...created!,
        'id': 'test-session',
        'state': 'draft',
        'version': 1,
        'spec_version': 0,
        'analysis_steps': 0,
        'can_edit': true,
        'specification': {'points': []},
        'jobs': [],
        'evidence': [],
        'measurements': [],
        'hypotheses': [],
        'interventions': [],
        'verifications': [],
      };
      return detail;
    }
    if (path == '/sessions/test-session') return detail;
    if (path == '/sessions' && detail != null) return [detail];
    return super.request(path, method: method, data: data);
  }
}

void main() {
  testWidgets('Native content stays outside system bars', (tester) async {
    SharedPreferences.setMockInitialValues({'circuitlab.language': 'en'});
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(TestApi())],
        child: const CircuitLabApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(Scaffold)).dy, 32);
    expect(tester.getBottomRight(find.byType(Scaffold)).dy, 616);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final language in ['en', 'es']) {
    for (final layout in [
      (width: 320.0, height: 640.0, keyboard: 260.0, scale: 1.0),
      (width: 568.0, height: 320.0, keyboard: 100.0, scale: 1.0),
      (width: 768.0, height: 1024.0, keyboard: 280.0, scale: 1.5),
      (width: 1440.0, height: 900.0, keyboard: 0.0, scale: 1.0),
    ]) {
      testWidgets(
        'Required inputs and symptom-free creation at $layout in $language',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'circuitlab.language': language,
          });
          tester.view.physicalSize = Size(layout.width, layout.height);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = layout.scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final api = CreationApi();
          final strings = AppStrings(language);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [apiProvider.overrideWithValue(api)],
              child: const CircuitLabApp(),
            ),
          );
          await tester.pumpAndSettle();
          final newButton = find.text(strings.t('newSession'));
          await tester.ensureVisible(newButton);
          await tester.tap(newButton);
          await tester.pumpAndSettle();
          expect(find.byType(RequiredFieldsNotice), findsOneWidget);
          final submit = find.widgetWithText(
            FilledButton,
            strings.t('createSession'),
          );
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(api.created, isNull);
          expect(find.text(strings.t('fieldRequired')), findsWidgets);
          final purpose = find.byType(DropdownButtonFormField<String>).first;
          await tester.ensureVisible(purpose);
          await tester.tap(purpose);
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('purposeCheckOperation')).last);
          await tester.pumpAndSettle();
          expect(find.byType(RequiredLabel), findsNWidgets(6));
          expect(find.text(strings.t('microcontrollerProject')), findsWidgets);
          final optional = find.widgetWithText(
            TextFormField,
            strings.t('optionalObservations'),
          );
          expect(
            tester.state<FormFieldState<String>>(optional).errorText,
            isNull,
          );

          for (final entry in {
            'sessionName': 'Guided check fixture',
            'projectSetup': 'ESP32 with temperature, RFID and GPS modules',
            'supplyVoltageMaximum5V': '3.3',
            'whatShouldItDo': 'Output remains within the declared range',
          }.entries) {
            final field = find.widgetWithText(TextField, strings.t(entry.key));
            await tester.ensureVisible(field);
            await tester.enterText(field, entry.value);
          }
          tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(api.created?['purpose'], 'check_operation');
          expect(api.created?['symptoms'], '');
          expect(api.created?['family'], 'microcontroller');
          expect(api.created?['supply_v'], 3.3);
          expect(api.created?['setup'], contains('ESP32'));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'Eight-point criteria fit with keyboard at $layout in $language',
        (tester) async {
          tester.view.physicalSize = Size(layout.width, layout.height);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = layout.scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            shell(
              language,
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => SpecificationDialog(
                        specification: specification(8),
                        supplyVoltage: 5,
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
          await tester.pumpAndSettle();
          final target = find.byKey(const ValueKey('TP8-max'));
          await tester.ensureVisible(target);
          await tester.enterText(target, '4.9');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
      for (final page in ['login', 'recovery', 'functional', 'admin']) {
        testWidgets(
          '$page form remains usable with keyboard at $layout in $language',
          (tester) async {
            SharedPreferences.setMockInitialValues({
              'circuitlab.language': language,
            });
            tester.view.physicalSize = Size(layout.width, layout.height);
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = layout.scale;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetViewInsets);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final strings = AppStrings(language);
            Widget root;
            if (page == 'login') {
              root = ProviderScope(
                overrides: [apiProvider.overrideWithValue(TestApi())],
                child: const CircuitLabApp(),
              );
            } else if (page == 'recovery') {
              root = ProviderScope(
                overrides: [apiProvider.overrideWithValue(TestApi())],
                child: shell(language, const RecoveryPage(resetting: true)),
              );
            } else {
              root = shell(
                language,
                Builder(
                  builder: (context) => Scaffold(
                    body: page == 'admin'
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: AccountsPanel(
                              api: AccountApi(authenticated: true),
                            ),
                          )
                        : TextButton(
                            onPressed: () => showDialog(
                              context: context,
                              builder: (_) => const FunctionalCheckDialog(
                                criteria:
                                    'Output stays stable under the declared operating conditions.',
                              ),
                            ),
                            child: const Text('Open'),
                          ),
                  ),
                ),
              );
            }
            await tester.pumpWidget(root);
            await tester.pumpAndSettle();
            if (page == 'functional') {
              await tester.tap(find.text('Open'));
              await tester.pumpAndSettle();
            }
            if (page == 'admin') {
              await tester.tap(find.text(strings.t('createUser')));
              await tester.pumpAndSettle();
            }
            expect(find.byType(RequiredLabel), findsWidgets);
            tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
            await tester.pumpAndSettle();
            final field = find.byType(TextField).last;
            await tester.ensureVisible(field);
            await tester.enterText(field, 'Fixture input');
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
