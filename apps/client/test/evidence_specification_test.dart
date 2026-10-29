import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/storage/outbox_web.dart' as web;
import 'package:circuitlab_client/features/specification_dialog.dart';
import 'package:circuitlab_client/features/workbench.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';

Widget shell(String language, Widget home) => MaterialApp(
  locale: Locale(language),
  supportedLocales: const [Locale('en'), Locale('es')],
  localizationsDelegates: const [
    AppStringsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: home,
);

Map<String, dynamic> specification(int count) => {
  'connections': ['Supply to input', 'Output to common ground'],
  'functional_description': 'Output remains inside its declared range.',
  'points': List.generate(
    count,
    (index) => {
      'id': 'TP${index + 1}',
      'label': 'Node ${index + 1}',
      'min_v': 0,
      'max_v': 5,
    },
  ),
};

DioException unauthorized(RequestOptions options) => DioException(
  requestOptions: options,
  type: DioExceptionType.badResponse,
  response: Response(requestOptions: options, statusCode: 401),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final language in ['en', 'es']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('Eight editable points preserve IDs at $width in $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Map<String, dynamic>? saved;
        final strings = AppStrings(language);
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
                        specification: specification(4),
                        supplyVoltage: 5,
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
        Future<void> fill(String id) async {
          final type = find.byKey(ValueKey('$id-kind'));
          await tester.ensureVisible(type);
          await tester.tap(type);
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.t('observationVoltageType')).last);
          await tester.pumpAndSettle();
          for (final entry in {
            'label': 'Node $id',
            'min': '0',
            'max': '5',
          }.entries) {
            final field = find.byKey(ValueKey('$id-${entry.key}'));
            await tester.ensureVisible(field);
            await tester.enterText(field, entry.value);
          }
        }

        for (var i = 5; i <= 8; i++) {
          final add = find.byKey(const ValueKey('add-test-point'));
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          await fill('TP$i');
        }
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('add-test-point')),
              )
              .onPressed,
          isNotNull,
        );
        final remove = find.byTooltip(
          strings.t('removeTestPoint', {'point': 'TP2'}),
        );
        await tester.ensureVisible(remove);
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('TP3-label')))
              .controller!
              .text,
          'Node 3',
        );
        final add = find.byKey(const ValueKey('add-test-point'));
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        await fill('TP2');
        await tester.tap(
          find.text(strings.t('iConfirmTheSchematicAndCriteria')),
        );
        await tester.pumpAndSettle();
        expect((saved!['points'] as List).length, 8);
        expect(
          (saved!['points'] as List).map((p) => p['id']).toSet(),
          List.generate(8, (i) => 'TP${i + 1}').toSet(),
        );
        expect(
          (saved!['points'] as List).firstWhere(
            (p) => p['id'] == 'TP3',
          )['label'],
          'Node 3',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('Invalid ranges stay in the editor without losing entries', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(
        'en',
        SpecificationDialog(
          specification: specification(1),
          supplyVoltage: 3.3,
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('TP1-min')), '3');
    await tester.enterText(find.byKey(const ValueKey('TP1-max')), '2');
    await tester.tap(
      find.text(AppStrings('en').t('iConfirmTheSchematicAndCriteria')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(AppStrings('en').t('testPointRangeInvalid')),
      findsWidgets,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('TP1-label')))
          .controller!
          .text,
      'Node 1',
    );
    await tester.enterText(find.byKey(const ValueKey('TP1-max')), '5');
    await tester.tap(
      find.text(AppStrings('en').t('iConfirmTheSchematicAndCriteria')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(AppStrings('en').t('testPointVoltageInvalid', {'max': '3.3'})),
      findsOneWidget,
    );
    expect(find.byType(SpecificationDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Polling rebuilds reuse the same evidence bytes and decoded image key',
    (tester) async {
      final api = CircuitApi(store: web.Outbox())..access = 'test-access';
      final png = File('web/icons/Icon-192.png').readAsBytesSync();
      var requests = 0;
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: png),
            );
          },
        ),
      );
      late StateSetter rebuild;
      var evidenceId = 'evidence-one';
      await tester.pumpWidget(
        shell(
          'en',
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return Scaffold(
                body: EvidenceThumbnail(
                  api: api,
                  sessionId: 'session',
                  evidence: {'id': evidenceId},
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original =
          tester.widget<Image>(find.byType(Image)).image as MemoryImage;
      for (var i = 0; i < 4; i++) {
        rebuild(() {});
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        final current =
            tester.widget<Image>(find.byType(Image)).image as MemoryImage;
        expect(identical(current.bytes, original.bytes), isTrue);
        expect(current, original);
      }
      expect(requests, 1);
      rebuild(() => evidenceId = 'evidence-two');
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );

  test(
    'Evidence downloads renew an expired access token and retry with the new token',
    () async {
      final api = CircuitApi(store: web.Outbox())
        ..access = 'expired-access'
        ..refresh = 'test-refresh';
      var refreshes = 0;
      var downloads = 0;
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/auth/refresh') {
              refreshes++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'access_token': 'fresh-access',
                    'refresh_token': 'fresh-refresh',
                  },
                ),
              );
            } else {
              downloads++;
              if (options.headers['Authorization'] == 'Bearer expired-access') {
                handler.reject(unauthorized(options));
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: [1, 2, 3],
                  ),
                );
              }
            }
          },
        ),
      );
      expect(await api.downloadEvidence('s', 'e'), [1, 2, 3]);
      expect(refreshes, 1);
      expect(downloads, 2);
      api.dispose();
    },
  );

  test(
    'A late 401 reuses a token already renewed by another request',
    () async {
      final api = CircuitApi(store: web.Outbox())
        ..access = 'expired-access'
        ..refresh = 'test-refresh';
      final release = Completer<void>();
      final started = Completer<void>();
      var refreshes = 0;
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.path == '/auth/refresh') {
              refreshes++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'access_token': 'fresh-access',
                    'refresh_token': 'fresh-refresh',
                  },
                ),
              );
            } else if (options.headers['Authorization'] ==
                'Bearer expired-access') {
              if (options.path == '/late') {
                started.complete();
                await release.future;
              }
              handler.reject(unauthorized(options));
            } else {
              handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: 'ok'),
              );
            }
          },
        ),
      );
      final delayed = api.request('/late');
      await started.future;
      expect(await api.request('/first'), 'ok');
      release.complete();
      expect(await delayed, 'ok');
      expect(refreshes, 1);
      api.dispose();
    },
  );
}
