import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/core/brand.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/storage/outbox_web.dart' as web;
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/main.dart';

class PublicApi extends CircuitApi {
  Map<String, String>? registration;
  PublicApi({bool authenticated = false}) : super(store: web.Outbox()) {
    if (authenticated) {
      access = 'test';
      email = 'member@example.test';
      account = {'role': 'member', 'email': email};
    }
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
  }) async => path == '/auth/me' ? account : [];
  @override
  Future<void> register(String mail, String password) async {
    registration = {'email': mail, 'password': password};
    email = mail;
    access = 'test';
    account = {'role': 'member', 'email': mail};
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'circuitlab.language': 'en'});
    FlutterSecureStorage.setMockInitialValues({});
  });
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
      testWidgets('Public registration and layout at $width in $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'circuitlab.language': language,
        });
        final api = PublicApi();
        final strings = AppStrings(language);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWithValue(api)],
            child: RepaintBoundary(key: boundary, child: const CircuitLabApp()),
          ),
        );
        await tester.pumpAndSettle();
        final loginPassword = find.widgetWithText(
          TextField,
          strings.t('password'),
        );
        await tester.enterText(loginPassword, 'visibility-check-123');
        expect(tester.widget<TextField>(loginPassword).obscureText, isTrue);
        await tester.tap(find.byTooltip(strings.t('showPassword')));
        await tester.pump();
        expect(tester.widget<TextField>(loginPassword).obscureText, isFalse);
        expect(
          tester.widget<TextField>(loginPassword).controller!.text,
          'visibility-check-123',
        );
        await tester.tap(find.byTooltip(strings.t('hidePassword')));
        await tester.pump();
        expect(tester.widget<TextField>(loginPassword).obscureText, isTrue);
        await tester.ensureVisible(find.text(strings.t('createAccountLink')));
        await tester.tap(find.text(strings.t('createAccountLink')));
        await tester.pumpAndSettle();
        expect(find.text(strings.t('confirmPassword')), findsOneWidget);
        if (Platform.environment['CIRCUITLAB_PREVIEWS'] == '1') {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.tools/previews/register_${language}_$width.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.enterText(
          find.byType(TextField).at(0),
          'student@example.test',
        );
        await tester.enterText(
          find.byType(TextField).at(1),
          'member-password-123',
        );
        await tester.enterText(
          find.byType(TextField).at(2),
          'different-password',
        );
        await tester.ensureVisible(find.text(strings.t('createAccount')));
        await tester.tap(find.text(strings.t('createAccount')));
        await tester.pumpAndSettle();
        expect(api.registration, isNull);
        expect(
          find.textContaining(strings.t('passwordsMustMatch')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byType(TextField).at(2),
          'member-password-123',
        );
        await tester.ensureVisible(find.text(strings.t('createAccount')));
        await tester.tap(find.text(strings.t('createAccount')));
        await tester.pumpAndSettle();
        expect(api.registration?['email'], 'student@example.test');
        expect(api.isAdmin, isFalse);
        expect(
          tester.getRect(find.byType(CircleAvatar)).right,
          greaterThan(width - 50),
        );
        expect(
          find.byType(CircuitBrand),
          width > 1000 ? findsOneWidget : findsNothing,
        );
        if (Platform.environment['CIRCUITLAB_PREVIEWS'] == '1') {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '../../.tools/previews/workspace_${language}_$width.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  test(
    'A human event renews activity; background ticks do not; idle time clears credentials',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final api = CircuitApi(store: web.Outbox(), clock: () => now);
      var calls = 0;
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            expect(options.path, '/auth/activity');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'idle_expires_at':
                      now.add(const Duration(hours: 4)).millisecondsSinceEpoch /
                      1000,
                },
              ),
            );
          },
        ),
      );
      await api.accept({
        'access_token': 'access',
        'refresh_token': 'refresh',
        'user': {'email': 'member@example.test', 'role': 'member'},
        'idle_expires_at':
            now.add(const Duration(hours: 4)).millisecondsSinceEpoch / 1000,
      });
      now = now.add(const Duration(hours: 1));
      await api.tickSession();
      expect(calls, 0);
      api.recordActivity();
      now = now.add(const Duration(minutes: 2));
      await api.tickSession();
      expect(calls, 0); // Stale offline input cannot prolong the session.
      api.recordActivity();
      await api.tickSession();
      expect(calls, 1);
      expect(api.idleDeadline!.toUtc(), now.add(const Duration(hours: 4)));
      now = now.add(const Duration(hours: 3));
      await api.tickSession();
      expect(calls, 1);
      now = now.add(const Duration(hours: 1));
      await api.tickSession();
      expect(api.signedIn, isFalse);
      expect(api.refresh, isNull);
      expect(api.account, isNull);
      expect(api.sessionExpired, isTrue);
      expect(await api.secure.read(key: 'refresh'), isNull);
    },
  );
}
