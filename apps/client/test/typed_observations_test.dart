import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/main.dart';
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;
import 'layout_test.dart' show TestApi;

Map<String, dynamic> digitalSpec() => {
  'connections': ['UI FIXTURE: confirmed output to input'],
  'functional_description': 'UI FIXTURE: idle output remains false.',
  'points': [
    {
      'id': 'TP1',
      'label': 'Idle output',
      'kind': 'digital_state',
      'value_kind': 'boolean',
      'expected_state': false,
    },
  ],
};

Map<String, dynamic> sessionFixture() => {
  'id': 'test-session',
  'title': 'Digital fixture',
  'family': 'digital_signal',
  'supply_v': 3.3,
  'state': 'awaiting_measurement',
  'version': 5,
  'spec_version': 1,
  'analysis_steps': 1,
  'can_edit': true,
  'expected': 'Idle output is false',
  'symptoms': 'State needs checking',
  'pending_test': {
    'action': 'request_manual_measurement',
    'point_id': 'TP1',
    'instruction': 'Observe the confirmed idle state.',
  },
  'specification': digitalSpec(),
  'jobs': [],
  'measurements': [],
  'evidence': [],
  'hypotheses': [],
  'verifications': [],
  'interventions': [],
};

class DeleteApi extends TestApi {
  Map<String, dynamic>? deletion;
  DeleteApi(Map<String, dynamic> fixture)
    : super(authenticated: true, fixture: fixture);
  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    if (method == 'DELETE') {
      deletion = Map<String, dynamic>.from(data);
      fixture!['evidence'] = [];
      fixture!['evidence_review_required'] = true;
      fixture!['state'] = 'ready';
      return null;
    }
    return super.request(path, method: method, data: data);
  }
}

class ProblemApi extends TestApi {
  Map<String, dynamic>? problem;
  Map<String, dynamic>? review;
  ProblemApi() : super(authenticated: true, fixture: sessionFixture());
  @override
  Future<dynamic> request(String path, {String method = 'GET', dynamic data}) async {
    if (method == 'POST' && path.endsWith('/diagnostic-context')) {
      problem = Map<String, dynamic>.from(data);
      return {'id': 'reported-problem'};
    }
    if (method == 'POST' && path.endsWith('/analysis')) {
      review = Map<String, dynamic>.from(data);
      return {'job_id': 'review-problem'};
    }
    return super.request(path, method: method, data: data);
  }
}

void main() {
  testWidgets('An unavailable reading is reported without a value or a GND confirmation', (tester) async {
    SharedPreferences.setMockInitialValues({'circuitlab.language': 'es'});
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final strings = AppStrings('es');
    final api = ProblemApi();
    await tester.pumpWidget(ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)], child: const CircuitLabApp(),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Digital fixture'));
    await tester.tap(find.text('Digital fixture'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(strings.t('recordMeasurement')));
    await tester.tap(find.text(strings.t('recordMeasurement')));
    await tester.pumpAndSettle();
    final report = find.byKey(const ValueKey('report-missing-reading'));
    await tester.ensureVisible(report);
    await tester.tap(report);
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNothing);
    final description = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextFormField));
    await tester.enterText(description, 'ERROR: DHT11 sin lectura valida.');
    await tester.tap(find.text(strings.t('saveAndReview')));
    await tester.pumpAndSettle();
    expect(api.problem?['kind'], 'problem');
    expect(api.problem?['point_id'], 'TP1');
    expect(api.problem?['content'], 'ERROR: DHT11 sin lectura valida.');
    expect(api.recorded, isNull);
    expect(api.review, {'evidence_id': 'reported-problem'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  for (final language in ['en', 'es']) {
    for (final width in [320.0, 1440.0]) {
      testWidgets(
        'Boolean criterion preserves expected false at $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 1200);
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
                          specification: digitalSpec(),
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
          final state = find.byKey(const ValueKey('TP1-expected-state'));
          await tester.ensureVisible(state);
          expect(
            tester.widget<DropdownButtonFormField<bool>>(state).initialValue,
            false,
          );
          expect(find.byKey(const ValueKey('TP1-min')), findsNothing);
          await tester.tap(
            find.text(strings.t('iConfirmTheSchematicAndCriteria')),
          );
          await tester.pumpAndSettle();
          final point = (saved!['points'] as List).single;
          expect(point['expected_state'], false);
          expect(point['value_kind'], 'boolean');
          expect(point.containsKey('min_v'), false);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'Manual false submits native boolean at $width in $language',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'circuitlab.language': language,
          });
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          final api = TestApi(authenticated: true, fixture: sessionFixture());
          await tester.pumpWidget(
            ProviderScope(
              overrides: [apiProvider.overrideWithValue(api)],
              child: const CircuitLabApp(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Digital fixture'));
          await tester.tap(find.text('Digital fixture'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(strings.t('recordMeasurement')));
          await tester.tap(find.text(strings.t('recordMeasurement')));
          await tester.pumpAndSettle();
          final state = find.byKey(const ValueKey('boolean-observed-value'));
          await tester.tap(state);
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('booleanFalse')).last);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('manual-criterion-feedback')), findsOneWidget);
          expect(find.text(strings.t('observationWithinCriterion')), findsOneWidget);
          expect(find.descendant(of: find.byType(AlertDialog),
            matching: find.byType(DropdownButtonFormField<String>)), findsNothing);
          await tester.ensureVisible(find.byType(CheckboxListTile));
          await tester.tap(find.byType(CheckboxListTile));
          await tester.tap(find.text(strings.t('saveReading')));
          await tester.pumpAndSettle();
          expect(api.recorded?['point_id'], 'TP1');
          expect(api.recorded?['unit'], 'boolean');
          expect(api.recorded?['value'], false);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final editable in [true, false]) {
    testWidgets(
      'Evidence deletion confirms before removal; editable=$editable',
      (tester) async {
        SharedPreferences.setMockInitialValues({'circuitlab.language': 'en'});
        tester.view.physicalSize = const Size(1440, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = AppStrings('en');
        final api = DeleteApi({
          ...sessionFixture(),
          'can_edit': editable,
          'evidence': [
            {'id': 'fixture-photo', 'sha256': 'fixture', 'mime': 'image/jpeg'},
          ],
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWithValue(api)],
            child: const CircuitLabApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Digital fixture'));
        await tester.tap(find.text('Digital fixture'));
        await tester.pumpAndSettle();
        final details = find.text(strings.t('detailsAndEvidence'));
        await tester.ensureVisible(details);
        await tester.tap(details);
        await tester.pumpAndSettle();
        final remove = find.text(strings.t('removeEvidence'));
        if (!editable) {
          expect(remove, findsNothing);
        } else {
          await tester.ensureVisible(remove);
          await tester.tap(remove);
          await tester.pumpAndSettle();
          expect(api.deletion, isNull);
          await tester.tap(find.text(strings.t('cancel')));
          await tester.pumpAndSettle();
          expect(api.deletion, isNull);
          await tester.tap(remove);
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text(strings.t('confirmRemoveEvidence')),
                )
                .last,
          );
          await tester.pumpAndSettle();
          expect(api.deletion, {'version': 5, 'confirmed': true});
          expect(
            find.byKey(const ValueKey('photo-tile-fixture-photo')),
            findsNothing,
          );
          expect(
            find.text(strings.t('evidenceReviewRequired')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
