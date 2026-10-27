import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/storage/outbox_web.dart' as web;
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/main.dart';

class AccountApi extends CircuitApi {
  final calls = <String>[];
  Map<String, dynamic>? lastBody;
  bool cleared = false;
  final users = <Map<String, dynamic>>[
    {
      'id': 'admin-id',
      'email': 'admin@example.test',
      'role': 'admin',
      'active': true,
    },
    {
      'id': 'member-id',
      'email': 'member@example.test',
      'role': 'member',
      'active': true,
    },
  ];
  AccountApi({bool authenticated = false}) : super(store: web.Outbox()) {
    if (authenticated) {
      access = 'test-access';
      email = 'admin@example.test';
      account = users.first;
    }
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls.add(options.path);
          if (options.data is Map) {
            lastBody = Map<String, dynamic>.from(options.data);
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: options.path == '/health/live'
                  ? {'ai_mode': 'simulation'}
                  : {'status': 'accepted'},
            ),
          );
        },
      ),
    );
  }
  @override
  Future<void> restore() async {}
  @override
  Future<void> clearCredentials({bool expired = false}) async {
    access = null;
    refresh = null;
    account = null;
    cleared = true;
  }

  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    calls.add('$method $path');
    if (path == '/auth/me') return users.first;
    if (path.startsWith('/admin/users?')) {
      return {'items': users, 'has_more': false};
    }
    if (path.startsWith('/admin/events')) {
      return {
        'items': [
          {
            'kind': 'user_created',
            'email': 'member@example.test',
            'user_id': 'member-id',
            'created_at': 1792800000,
          },
        ],
        'has_more': false,
      };
    }
    if (path == '/admin/users' && method == 'POST') {
      lastBody = Map<String, dynamic>.from(data);
      users.add({
        'id': 'new-id',
        'email': data['email'],
        'role': data['role'],
        'active': true,
      });
      return users.last;
    }
    if (method == 'PATCH') {
      lastBody = Map<String, dynamic>.from(data);
      final user = users.firstWhere((u) => path.endsWith(u['id']));
      user.addAll(lastBody!);
      return user;
    }
    return [];
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
    final strings = AppStrings(language);
    for (final width in [390.0, 1440.0]) {
      Future<void> mount(WidgetTester tester, CircuitApi api) async {
        SharedPreferences.setMockInitialValues({
          'circuitlab.language': language,
        });
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWithValue(api)],
            child: const CircuitLabApp(),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets(
        'Recovery validates confirmation and clears credentials $language $width',
        (tester) async {
          final api = AccountApi();
          await mount(tester, api);
          await tester.ensureVisible(find.text(strings.t('forgotPassword')));
          await tester.tap(find.text(strings.t('forgotPassword')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextFormField, strings.t('emailAddress')),
            'student@example.test',
          );
          await tester.tap(find.text(strings.t('sendRecoveryLink')));
          await tester.pumpAndSettle();
          expect(api.calls, contains('/auth/forgot-password'));
          expect(api.lastBody?['email'], 'student@example.test');
          expect(find.text(strings.t('recoveryAccepted')), findsOneWidget);
          await tester.tap(find.text(strings.t('backToLogin')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(strings.t('forgotPassword')));
          await tester.tap(find.text(strings.t('forgotPassword')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('haveRecoveryCode')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextFormField, strings.t('recoveryCode')),
            'a' * 64,
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, strings.t('newPassword')),
            'new-password-1234',
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, strings.t('confirmPassword')),
            'different-password',
          );
          await tester.ensureVisible(find.text(strings.t('savePassword')));
          await tester.tap(find.text(strings.t('savePassword')));
          await tester.pumpAndSettle();
          expect(find.text(strings.t('passwordMismatch')), findsOneWidget);
          expect(api.calls, isNot(contains('/auth/reset-password')));
          await tester.enterText(
            find.widgetWithText(TextFormField, strings.t('confirmPassword')),
            'new-password-1234',
          );
          await tester.tap(find.text(strings.t('savePassword')));
          await tester.pumpAndSettle();
          expect(api.lastBody?['password'], 'new-password-1234');
          expect(api.cleared, isTrue);
          expect(find.text(strings.t('passwordUpdated')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets('Admin creates and deactivates users $language $width', (
        tester,
      ) async {
        final api = AccountApi(authenticated: true);
        await mount(tester, api);
        if (width < 1000) {
          await tester.tap(find.byIcon(Icons.menu));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(strings.t('users')));
        await tester.pumpAndSettle();
        if (const bool.fromEnvironment('CAPTURE_PREVIEWS')) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../../../.tools/previews/accounts_${language}_$width.png',
            ),
          );
        }
        await tester.tap(find.text(strings.t('createUser')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, strings.t('emailAddress')),
          'new@example.test',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, strings.t('initialPassword')),
          'initial-password-123',
        );
        final initialPassword = find.descendant(
          of: find.widgetWithText(TextFormField, strings.t('initialPassword')),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(initialPassword).obscureText, isTrue);
        await tester.tap(find.byTooltip(strings.t('showPassword')));
        await tester.pump();
        expect(tester.widget<TextField>(initialPassword).obscureText, isFalse);
        expect(
          tester.widget<TextField>(initialPassword).controller!.text,
          'initial-password-123',
        );
        await tester.tap(find.byTooltip(strings.t('hidePassword')));
        await tester.pump();
        expect(tester.widget<TextField>(initialPassword).obscureText, isTrue);

        await tester.tap(
          find.widgetWithText(FilledButton, strings.t('createUser')).last,
        );
        await tester.pumpAndSettle();
        expect(api.lastBody?['email'], 'new@example.test');
        expect(find.text('new@example.test'), findsOneWidget);
        final card = find.ancestor(
          of: find.text('member@example.test'),
          matching: find.byType(Card),
        );
        final deactivate = find.descendant(
          of: card,
          matching: find.text(strings.t('deactivateUser')),
        );
        await tester.ensureVisible(deactivate);
        await tester.tap(deactivate);
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.t('confirm')));
        await tester.pumpAndSettle();
        expect(api.users[1]['active'], isFalse);
        expect(find.text(strings.t('accountInactive')), findsOneWidget);
        await tester.ensureVisible(find.text(strings.t('accountActivity')));
        await tester.tap(find.text(strings.t('accountActivity')));
        await tester.pumpAndSettle();
        expect(find.text(strings.t('user_created')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}
