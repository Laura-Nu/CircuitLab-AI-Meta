import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'package:circuitlab_client/l10n/language.dart';
import 'package:circuitlab_client/main.dart';
import 'layout_test.dart' show TestApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'circuitlab.language': 'es'}),
  );

  testWidgets('Switching language preserves input and saves the choice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = TestApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: const CircuitLabApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Correo electrónico'),
      'student@example.test',
    );
    await tester.tap(find.byType(LanguageSelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('student@example.test'), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      const Locale('en'),
    );
    expect(api.language, 'en');
    expect(
      (await SharedPreferences.getInstance()).getString('circuitlab.language'),
      'en',
    );
    await tester.tap(find.byType(LanguageSelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-es')));
    await tester.pumpAndSettle();
    expect(find.text('Correo electrónico'), findsOneWidget);
    expect(find.text('student@example.test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'Saved locale is restored and unsupported selections are ignored',
    () async {
      SharedPreferences.setMockInitialValues({'circuitlab.language': 'en'});
      final controller = LanguageController();
      await controller.restore();
      expect(controller.state.languageCode, 'en');
      await controller.select('es');
      await controller.select('fr');
      expect(controller.state.languageCode, 'es');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'circuitlab.language',
        ),
        'es',
      );
      controller.dispose();
    },
  );

  test(
    'Landing language overrides an older saved preference and remains selected',
    () async {
      SharedPreferences.setMockInitialValues({'circuitlab.language': 'es'});
      final controller = LanguageController(requestedLanguage: 'en');
      expect(controller.state.languageCode, 'en');
      await controller.restore();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.languageCode, 'en');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'circuitlab.language',
        ),
        'en',
      );
      controller.dispose();
    },
  );

  test(
    'API requests carry the selected language and offline errors are translated',
    () async {
      final api = CircuitApi()..language = 'en';
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.headers['Accept-Language'], 'en');
            handler.resolve(Response(requestOptions: options, statusCode: 200));
          },
        ),
      );
      await api.dio.get('/health/live');
      final error = DioException(
        requestOptions: RequestOptions(path: '/sessions'),
        type: DioExceptionType.connectionError,
      );
      expect(errorMessage(error, language: 'en'), startsWith('Cannot connect'));
      expect(errorMessage(error, language: 'es'), startsWith('Sin conexión'));
      expect(
        const AppStrings('en').t('pendingSync', {'count': 2}),
        startsWith('2 records'),
      );
    },
  );
}
