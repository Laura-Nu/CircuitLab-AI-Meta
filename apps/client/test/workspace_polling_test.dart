import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/main.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'layout_test.dart' show TestApi;

class EfficientApi extends TestApi {
  int workspaceCalls = 0, progressCalls = 0;
  final paths = <String>[];
  EfficientApi(Map<String, dynamic> session)
    : super(authenticated: true, fixture: session);
  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    paths.add(path);
    if (path == '/workspace') {
      workspaceCalls++;
      return {
        'account': {'id': 'owner', 'role': 'member'},
        'health': {
          'ai_mode': 'meta',
          'provider_configured': true,
          'simulation_allowed': false,
        },
        'devices': <dynamic>[],
        'sessions': [
          {
            for (final key in [
              'id',
              'title',
              'family',
              'supply_v',
              'state',
              'version',
            ])
              key: fixture![key],
          },
        ],
      };
    }
    if (path.startsWith('/sessions/test-session/progress?')) {
      progressCalls++;
      final known = int.parse(
        Uri.parse(path).queryParameters['known_version']!,
      );
      return {
        'id': fixture!['id'],
        'version': fixture!['version'],
        'state': fixture!['state'],
        'snapshot': known == fixture!['version'] ? null : fixture,
        'jobs': fixture!['jobs'],
        'events': <dynamic>[],
        'analysis_phase': fixture!['state'] == 'analyzing' ? 'comparing' : null,
      };
    }
    return super.request(path, method: method, data: data);
  }
}

void main() {
  testWidgets(
    'Idle polls fetch only progress, update on change and pause in the background',
    (tester) async {
      SharedPreferences.setMockInitialValues({'circuitlab.language': 'en'});
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = <String, dynamic>{
        'id': 'test-session',
        'title': 'Efficient polling circuit',
        'family': 'voltage_divider',
        'supply_v': 5,
        'version': 5,
        'state': 'awaiting_measurement',
        'spec_version': 1,
        'analysis_steps': 1,
        'can_edit': true,
        'expected': 'Stable output',
        'symptoms': 'Output low',
        'measurements': [],
        'evidence': [],
        'hypotheses': [],
        'verifications': [],
        'jobs': [],
        'specification': {'points': []},
        'pending_test': {
          'point_id': 'TP1',
          'instruction': 'Measure the output',
          'rationale': 'Check its value',
        },
      };
      final api = EfficientApi(fixture);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWithValue(api)],
          child: const CircuitLabApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Efficient polling circuit'));
      await tester.pumpAndSettle();
      final full = api.workspaceCalls;
      final polls = api.progressCalls;
      expect(full, 2);
      expect(polls, 1);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(api.workspaceCalls, full);
      expect(api.progressCalls, polls + 1);
      expect(
        api.paths.where(
          (p) => ['/sessions', '/auth/me', '/devices'].contains(p),
        ),
        isEmpty,
      );
      expect(find.text('Measure the output'), findsOneWidget);
      fixture['version'] = 6;
      fixture['state'] = 'analyzing';
      fixture['jobs'] = [
        {'kind': 'analysis', 'status': 'running', 'attempts': 1},
      ];
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.text(AppStrings('en').t('analysisPhaseComparing')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings('en').t('analysisProgressNotice')),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final beforeBackground = api.progressCalls;
      final beforeBackgroundWorkspace = api.workspaceCalls;
      await tester.pump(const Duration(seconds: 12));
      expect(api.progressCalls, beforeBackground);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.progressCalls, greaterThan(beforeBackground));
      expect(api.workspaceCalls, beforeBackgroundWorkspace + 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
