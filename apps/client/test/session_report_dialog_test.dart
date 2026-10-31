import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/session_report_dialog.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

Map<String, dynamic> reportFixture() => {
  'id': 'private-session-id',
  'title': 'A project with multiple recorded observations',
  'state': 'inconclusive',
  'purpose': 'check_operation',
  'family': 'custom',
  'analysis_steps': 2,
  'diagnosis_mode': 'simulation',
  'supply_v': 5.0,
  'expected': 'Expected circuit behavior',
  'symptoms': '',
  'setup': 'ESP32 and sensors',
  'markdown': '# Export only\nComplete original report.',
  'presentation': {
    'state': 'State label',
    'family': 'Project label',
    'events': [
      {'sequence': 1, 'label': 'Saved observation'},
    ],
  },
  'specification': {
    'connections': ['Confirmed module wiring'],
    'functional_description': 'Observe operation under the declared condition',
    'points': [
      {'id': 'TP1', 'label': 'Reader supply', 'min_v': 4.8, 'max_v': 5.0},
      {
        'id': 'TP2',
        'label': 'Card detected',
        'value_kind': 'boolean',
        'expected_state': false,
      },
      {
        'id': 'TP3',
        'label': 'Card UID',
        'value_kind': 'text',
        'expected_text': '04:A1',
      },
      {
        'id': 'TP4',
        'label': 'Temperature',
        'value_kind': 'number',
        'unit': 'C',
        'min_value': 20,
        'max_value': 30,
      },
    ],
  },
  'measurements': [
    for (final tuple in [
      ['TP1', 5.0, 'V'],
      ['TP2', false, 'boolean'],
      ['TP3', '04:A1', 'text'],
      ['TP4', 25.5, 'C'],
    ])
      {
        'id': tuple[0],
        'point_id': tuple[0],
        'value': tuple[1],
        'unit': tuple[2],
        'source': 'serial_reported',
        'phase': 'diagnosis',
        'measured_at': 1234567890,
      },
  ],
  'hypotheses': [
    {
      'data': {
        'analysis_step': 1,
        'cause': 'Older explanation',
        'explanation': 'Historical basis',
      },
    },
    {
      'data': {
        'analysis_step': 2,
        'cause': 'Current explanation',
        'explanation': 'Current basis',
        'status': 'proposed',
        'evidence_ids': [],
      },
    },
  ],
  'pending_test': {
    'observations': ['Available recorded evidence'],
  },
  'verifications': [
    {
      'created_at': 1234567890,
      'data': {
        'passed': false,
        'physical_verification': true,
        'checks': [],
        'functional_check': {
          'passed': false,
          'criteria': 'Physical condition',
          'observations': 'Observed functional failure',
        },
      },
    },
  ],
  'evidence': [
    {'id': 'photo-id', 'mime': 'image/jpeg', 'sha256': 'private-image-hash'},
  ],
  'removed_evidence': [
    {'id': 'withdrawn-photo', 'mime': 'image/jpeg'},
  ],
  'evidence_review_required': true,
  'events': [
    {
      'sequence': 1,
      'kind': 'serial_reading_received',
      'created_at': 1234567890,
      'data': {
        'measurement_id': 'TP4',
        'channel': 'temperature',
        'sensor': 'DHT11',
      },
    },
    {
      'sequence': 2,
      'kind': 'serial_captured',
      'created_at': 1234567890,
      'data': {
        'lines': ['Recorded log'],
      },
    },
    {
      'sequence': 3,
      'kind': 'investigation_closed',
      'created_at': 1234567890,
      'data': {'reason': 'Not enough evidence'},
    },
  ],
  'model_runs': [
    {
      'data': {'model': 'admin-model-name', 'provider': 'admin-provider'},
    },
  ],
  'limitations': ['A source limitation'],
  'interventions': [
    {'created_at': 1234567890, 'description': 'Recorded human action'},
  ],
  'storyboards': [
    {
      'data': {
        'title': {'en': 'Story', 'es': 'Historia'},
        'notice': {'en': 'Story notice', 'es': 'Aviso'},
        'frames': [],
      },
    },
  ],
};

Future<void> open(
  WidgetTester tester,
  Map<String, dynamic> data,
  String language, {
  bool admin = false,
  double textScale = 1,
}) async {
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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  SessionReportDialog(report: data, technicalDetails: admin),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['es', 'en']) {
    for (final width in [320.0, 1440.0]) {
      testWidgets('Readable report and snapshot copy at $width in $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = call.arguments['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final data = reportFixture();
        final strings = AppStrings(language);
        await open(tester, data, language);
        expect(find.text(data['title'] as String), findsOneWidget);
        expect(find.textContaining('# Export only'), findsNothing);
        expect(find.byKey(const ValueKey('copy-report-json')), findsNothing);
        expect(find.text('admin-model-name'), findsNothing);
        expect(find.text('5.000 V'), findsNothing);
        expect(find.text('5 V'), findsWidgets);
        expect(
          find.text('25.5 C'),
          language == 'en' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('25,5 C'),
          language == 'es' ? findsOneWidget : findsNothing,
        );
        expect(find.text(strings.booleanValue(false)), findsOneWidget);
        expect(find.text(strings.t('reportPhysicalVerified')), findsNothing);
        await tester.ensureVisible(
          find.text(strings.t('thisDoesNotEstablishFullPhysicalVerification')),
        );
        expect(find.text('Observed functional failure'), findsOneWidget);
        final criteria = find.text(strings.t('reportCriteria'));
        await tester.ensureVisible(criteria);
        await tester.tap(criteria);
        await tester.pumpAndSettle();
        expect(
          find.text('Confirmed module wiring').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('copy-report-text')));
        await tester.pumpAndSettle();
        expect(clipboard, data['markdown']);
        expect(find.text(strings.t('copiedToClipboard')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('close-report')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('session-report-dialog')),
          findsNothing,
        );
      });
    }
  }

  testWidgets(
    'Administrator exports structured snapshot and small dialogs scroll',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = call.arguments['text'];
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(tester, reportFixture(), 'es', admin: true, textScale: 1.3);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('copy-report-json')));
      await tester.pumpAndSettle();
      expect(clipboard, contains('"model": "admin-model-name"'));
      expect(clipboard, isNot(contains('"markdown"')));
      await tester.tap(find.byKey(const ValueKey('close-report-icon')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-report-dialog')), findsNothing);
    },
  );

  testWidgets('Empty report does not invent readings or verification', (
    tester,
  ) async {
    final data = reportFixture()
      ..['measurements'] = []
      ..['verifications'] = [];
    await open(tester, data, 'en');
    expect(
      find.text(const AppStrings('en').t('reportReadingsEmpty')),
      findsOneWidget,
    );
    expect(
      find.text(const AppStrings('en').t('reportVerificationEmpty')),
      findsOneWidget,
    );
    expect(
      find.text(const AppStrings('en').t('reportPhysicalVerified')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
