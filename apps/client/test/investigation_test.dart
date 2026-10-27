import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/features/investigation.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

Map<String, dynamic> fixture({bool complete = true}) => {
  'state': 'resolved',
  'can_edit': true,
  'analysis_steps': 2,
  'storyboard_available': true,
  'storyboard_mode': 'meta',
  'agent_trace': [
    {
      'id': 'run-1',
      'provider': 'baseten',
      'model': 'meta-models/muse-spark-open-1026',
      'response_model': 'meta-models/muse-spark-open-1026',
      'request_id': 'provider-request-123',
      'output': {
        'point_id': 'TP1',
        'rationale': 'Compare the supply with a shorted output.',
        'hypotheses': [
          {'cause': 'Supply disconnected'},
          {'cause': 'Output shorted'},
        ],
        'test_predictions': [
          {
            'hypothesis_index': 0,
            'expected_outcome': {
              'en': 'Low supply voltage',
              'es': 'Alimentación baja',
            },
          },
          {
            'hypothesis_index': 1,
            'expected_outcome': {
              'en': 'Normal supply voltage',
              'es': 'Alimentación normal',
            },
          },
        ],
      },
    },
  ],
  'storyboards': complete
      ? [
          {
            'status': 'completed',
            'stale': false,
            'data': {
              'simulation': true,
              'diagnosis_mode': 'simulation',
              'title': {'en': 'The missing signal', 'es': 'La señal ausente'},
              'notice': {
                'en': 'Review captions against recorded sources.',
                'es': 'Revisa el relato contra las fuentes registradas.',
              },
              'frames': [
                {
                  'headline': {
                    'en': 'A circuit with a question',
                    'es': 'Un circuito y una pregunta',
                  },
                  'caption': {
                    'en': 'The expected output was fixed before diagnosis.',
                    'es': 'La salida esperada se fijó antes del diagnóstico.',
                  },
                  'source_ids': ['specification'],
                },
                {
                  'headline': {
                    'en': 'A result we can inspect',
                    'es': 'Un resultado que podemos revisar',
                  },
                  'caption': {
                    'en': 'The recorded test met its numerical criterion.',
                    'es': 'La prueba registrada cumplió el criterio numérico.',
                  },
                  'source_ids': ['measurement:m1', 'verification:v1'],
                },
              ],
              'facts': [
                {
                  'id': 'specification',
                  'kind': 'specification',
                  'data': {
                    'expected': 'Output at 2.5 V',
                    'specification': {
                      'points': [
                        {'id': 'TP1', 'min_v': 2.4, 'max_v': 2.6},
                      ],
                    },
                  },
                },
                {
                  'id': 'measurement:m1',
                  'kind': 'measurement',
                  'data': {
                    'point_id': 'TP1',
                    'value': 2.5,
                    'source': 'simulated',
                    'calibration_id': 'fixture-reference',
                  },
                },
                {
                  'id': 'verification:v1',
                  'kind': 'verification',
                  'data': {
                    'data': {
                      'passed': true,
                      'physical_verification': false,
                      'checks': [
                        {
                          'point_id': 'TP1',
                          'value': 2.5,
                          'min_v': 2.4,
                          'max_v': 2.6,
                        },
                      ],
                    },
                  },
                },
              ],
              'audit': {'provider': 'meta', 'model': 'muse-wonder-1.0'},
              'source_sha256':
                  'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
            },
          },
        ]
      : [],
};

Widget app(
  String language,
  Map<String, dynamic> session,
  VoidCallback create,
) => MaterialApp(
  locale: Locale(language),
  supportedLocales: const [Locale('en'), Locale('es')],
  localizationsDelegates: const [
    AppStringsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: ThemeData.dark(useMaterial3: true).copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff6ce5bc),
      brightness: Brightness.dark,
    ),
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: InvestigationPanels(
          session: session,
          busy: false,
          onGenerate: create,
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final language in ['en', 'es']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'Story, sources and predictions work at $width in $language',
        (tester) async {
          tester.view.physicalSize = Size(width, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final strings = AppStrings(language);
          await tester.pumpWidget(app(language, fixture(), () {}));
          await tester.pumpAndSettle();
          expect(
            find.text(
              language == 'en' ? 'The missing signal' : 'La señal ausente',
            ),
            findsOneWidget,
          );
          expect(find.text(strings.t('storySimulation')), findsOneWidget);
          await tester.tap(find.text('1. meta-models/muse-spark-open-1026'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              language == 'en' ? 'Low supply voltage' : 'Alimentación baja',
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.text(strings.t('storySource_verification')),
          );
          await tester.tap(find.text(strings.t('storySource_verification')));
          await tester.pumpAndSettle();
          expect(
            find.text(
              strings.t('thisDoesNotEstablishFullPhysicalVerification'),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE_PREVIEWS')) {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../../../.tools/previews/investigation_${language}_$width.png',
              ),
            );
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets('Only the owner of a completed session can request a story', (
    tester,
  ) async {
    var created = 0;
    final strings = AppStrings('en');
    await tester.pumpWidget(
      app('en', fixture(complete: false), () => created++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.t('createStory')));
    expect(created, 1);
    final reader = fixture(complete: false)..['can_edit'] = false;
    await tester.pumpWidget(app('en', reader, () => created++));
    await tester.pumpAndSettle();
    expect(find.text(strings.t('createStory')), findsNothing);
    final ongoing = fixture(complete: false)
      ..['state'] = 'awaiting_measurement';
    await tester.pumpWidget(app('en', ongoing, () => created++));
    await tester.pumpAndSettle();
    expect(find.text(strings.t('createStory')), findsNothing);
    expect(
      find.text(strings.t('storyNeedsCompletedDiagnosis')),
      findsOneWidget,
    );
  });
}
