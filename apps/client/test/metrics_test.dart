import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/storage/outbox_web.dart' as web;
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/main.dart';

class MetricsApi extends CircuitApi {
  final paths = <String>[];
  final bool administrator;
  MetricsApi({this.administrator = true}) : super(store: web.Outbox()) {
    access = 'unit-test-access';
    email = 'metrics@example.test';
    account = {
      'id': 'test-user',
      'role': administrator ? 'admin' : 'member',
      'active': true,
    };
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'ai_mode': 'meta', 'provider_configured': true},
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
    paths.add(path);
    if (path == '/auth/me') return account;
    if (!path.startsWith('/admin/metrics')) return [];
    final live = Platform.environment['CIRCUITLAB_METRICS_PREVIEW_DATA'];
    if (live != null) return jsonDecode(File(live).readAsStringSync());
    return {
      'generated_at': 1793100000,
      'runtime': {
        'ai_mode': 'meta',
        'provider': 'meta',
        'model': 'enabled-test-model',
        'configured': true,
      },
      'inference': {
        'requests': 12,
        'http_success_rate': 75.0,
        'p95_latency_ms': 950,
        'latency_samples': 12,
        'total_tokens': 1234,
        'prompt_tokens': 1000,
        'completion_tokens': 234,
        'accepted_diagnoses': 2,
        'failed_diagnostic_attempts': 1,
        'tool_executions': 3,
        'simulation_steps': path.contains('mode=all') ? 2 : 0,
        'usage_reported_calls': 9,
      },
      'daily': List.generate(
        7,
        (i) => {
          'day': '2026-10-${21 + i}',
          'requests': [0, 1, 2, 0, 3, 2, 4][i],
          'tokens': i * 50,
          'mean_latency_ms': i == 0 ? null : 200 + i * 100,
          'http_errors': i == 3 ? 1 : 0,
          'transport_errors': 0,
          'simulation_steps': 0,
        },
      ),
      'sessions': {
        'created': 2,
        'current_states': {'awaiting_measurement': 2},
        'physical_verifications': 0,
      },
      'measurements': {'instrumented': 0, 'manual': 0, 'simulated': 1},
      'queue': {'pending': 0, 'running': 0},
      'models': [
        {
          'provider': 'meta',
          'model': 'enabled-test-model',
          'requests': 12,
          'http_errors': 3,
          'tokens': 1234,
        },
      ],
      'recent_calls': [
        {
          'created_at': 1793100000,
          'provider': 'meta',
          'model': 'enabled-test-model',
          'outcome': 'truncated',
          'http_status': 200,
          'duration_ms': null,
          'tokens': 0,
          'usage_reported': false,
        },
      ],
    };
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final language in ['es', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'Administrator metrics filters, charts and responsive layout $language $width',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'circuitlab.language': language,
          });
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = MetricsApi();
          final strings = AppStrings(language);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [apiProvider.overrideWithValue(api)],
              child: const CircuitLabApp(),
            ),
          );
          await tester.pumpAndSettle();
          if (width < 1000) {
            await tester.tap(find.byIcon(Icons.menu));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text(strings.t('metricsNav')));
          await tester.pumpAndSettle();
          expect(find.text(strings.t('metricsTitle')), findsOneWidget);
          expect(api.paths, contains('/admin/metrics?days=30&mode=real'));
          expect(
            find.text(strings.t('metricsAccuracyUnavailable')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE_PREVIEWS')) {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../../../.tools/previews/metrics_${language}_$width.png',
              ),
            );
          }
          await tester.tap(find.byKey(const ValueKey('metrics-days-30')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(strings.t('metricsDays', {'days': 7})).last,
          );
          await tester.pumpAndSettle();
          expect(api.paths, contains('/admin/metrics?days=7&mode=real'));
          await tester.ensureVisible(
            find.byKey(const ValueKey('metrics-mode-real')),
          );
          await tester.tap(find.byKey(const ValueKey('metrics-mode-real')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('metricsMode_all')).last);
          await tester.pumpAndSettle();
          expect(api.paths, contains('/admin/metrics?days=7&mode=all'));
          final tokens = find.widgetWithText(
            ChoiceChip,
            strings.t('metricsSeries_tokens'),
          );
          await tester.ensureVisible(tokens);
          await tester.tap(tokens);
          await tester.pumpAndSettle();
          expect(tester.widget<ChoiceChip>(tokens).selected, isTrue);
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE_PREVIEWS')) {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../../../.tools/previews/metrics_chart_${language}_$width.png',
              ),
            );
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets('A member never sees the administrative metrics navigation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'circuitlab.language': 'en'});
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = MetricsApi(administrator: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: const CircuitLabApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(const AppStrings('en').t('metricsNav')), findsNothing);
    expect(api.paths.where((p) => p.startsWith('/admin/metrics')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
