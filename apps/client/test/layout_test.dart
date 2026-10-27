import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/storage/outbox_web.dart' as web;
import 'package:circuitlab_client/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

class TestApi extends CircuitApi {
  final Map<String, dynamic>? fixture;
  Map<String, dynamic>? recorded;
  TestApi({bool authenticated = false, this.fixture})
    : super(store: web.Outbox()) {
    if (authenticated) {
      access = 'test';
      email = 'lab@example.test';
    }
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              data: {'ai_mode': 'simulation'},
              statusCode: 200,
            ),
          );
        },
      ),
    );
  }
  @override
  Future<void> restore() async {}
  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    if (path == '/sessions' && fixture != null) return [fixture];
    if (path == '/sessions/test-session') return fixture;
    return [];
  }

  @override
  Future<bool> saveMeasurement(
    String sessionId,
    Map<String, dynamic> value,
  ) async {
    recorded = value;
    return true;
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'circuitlab.language': 'es'}),
  );
  setUpAll(() async {
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final language in ['es', 'en']) {
    final strings = AppStrings(language);
    for (final width in [390.0, 1440.0]) {
      testWidgets('Guided measurement can be recorded at $width in $language', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({
          'circuitlab.language': language,
        });
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = TestApi(
          authenticated: true,
          fixture: {
            'id': 'test-session',
            'title': 'Divisor del laboratorio',
            'family': 'voltage_divider',
            'supply_v': 5,
            'state': 'awaiting_measurement',
            'spec_version': 1,
            'analysis_steps': 1,
            'expected': 'Salida estable a 2.5 V',
            'symptoms': 'La salida fluctúa',
            'can_edit': true,
            'pending_test': {
              'point_id': 'TP1',
              'instruction': 'Mide TP1 respecto a GND',
              'rationale': 'Contrastar la salida',
            },
            'specification': {
              'points': [
                {'id': 'TP1', 'label': 'Salida', 'min_v': 2.4, 'max_v': 2.6},
              ],
            },
            'measurements': [],
            'evidence': [],
            'hypotheses': [],
            'verifications': [],
          },
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWithValue(api)],
            child: const CircuitLabApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Divisor del laboratorio'));
        await tester.tap(find.text('Divisor del laboratorio'));
        await tester.pumpAndSettle();
        expect(find.text('Mide TP1 respecto a GND'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(strings.t('recordMeasurement')));
        await tester.tap(find.text(strings.t('recordMeasurement')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, strings.t('readingInV05')),
          '0.04',
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.tap(find.text(strings.t('saveReading')));
        await tester.pumpAndSettle();
        expect(api.recorded?['value'], .04);
        expect(api.recorded?['conditions_confirmed'], isTrue);
        expect(api.recorded?['point_id'], 'TP1');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets('Login fits a $width viewport in $language', (tester) async {
        SharedPreferences.setMockInitialValues({
          'circuitlab.language': language,
        });
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWithValue(TestApi())],
            child: const CircuitLabApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.t('emailAddress')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (width == 1440 && const bool.fromEnvironment('CAPTURE_PREVIEWS')) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/login_$language.png'),
          );
        }
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets(
        'Dashboard and creation dialog fit a $width viewport in $language',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'circuitlab.language': language,
          });
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                apiProvider.overrideWithValue(TestApi(authenticated: true)),
              ],
              child: const CircuitLabApp(),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(strings.t('diagnosticSessions')), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (width == 1440 && const bool.fromEnvironment('CAPTURE_PREVIEWS')) {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile('goldens/dashboard_$language.png'),
            );
          }
          await tester.tap(find.text(strings.t('newSession')));
          await tester.pumpAndSettle();
          expect(find.text(strings.t('whatShouldItDo')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(strings.t('cancel')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
