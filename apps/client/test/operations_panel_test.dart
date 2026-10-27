import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/storage/outbox_web.dart' as web;
import 'package:circuitlab_client/features/operations_panel.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

class OperationsApi extends CircuitApi {
  final requests = <String>[];
  bool delivered = false;
  OperationsApi() : super(store: web.Outbox()) {
    account = {'role': 'admin'};
  }
  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    requests.add('$method $path');
    if (path.endsWith('/refresh')) {
      delivered = true;
      return {};
    }
    return {
      'items': [
        {
          'id': 'safe-receipt-id',
          'provider': 'resend',
          'can_refresh': true,
          'status': delivered ? 'delivered' : 'accepted',
        },
      ],
    };
  }
}

void main() {
  for (final language in ['en', 'es']) {
    testWidgets(
      'Operations reports receipt acceptance separately and only refreshes status in $language',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = OperationsApi();
        final strings = AppStrings(language);
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
            home: Scaffold(
              body: SingleChildScrollView(
                child: OperationsPanel(
                  api: api,
                  status: const {
                    'worker': {'healthy': false},
                    'queue': {
                      'oldest_pending_seconds': 95,
                      'expired_leases': 1,
                    },
                    'budget': {
                      'used_attempts': 3,
                      'global_limit': 200,
                      'per_user_limit': 20,
                    },
                    'email': {
                      'last_24h': {'accepted': 1},
                      'stale_pending': 1,
                    },
                  },
                ),
              ),
            ),
          ),
        );
        expect(find.text(strings.t('workerUnavailable')), findsOneWidget);
        expect(find.text(strings.t('emailDispatchStale')), findsOneWidget);
        await tester.tap(find.text(strings.t('viewEmailReceipts')));
        await tester.pumpAndSettle();
        expect(find.text(strings.t('emailStatus_delivered')), findsNothing);
        await tester.ensureVisible(find.text(strings.t('refreshEmailStatus')));
        await tester.tap(find.text(strings.t('refreshEmailStatus')));
        await tester.pumpAndSettle();
        expect(find.text(strings.t('emailStatus_delivered')), findsOneWidget);
        expect(api.requests, [
          'GET /admin/email-deliveries',
          'POST /admin/email-deliveries/safe-receipt-id/refresh',
          'GET /admin/email-deliveries',
        ]);
        expect(tester.takeException(), isNull);
        api.dispose();
      },
    );
  }
}
