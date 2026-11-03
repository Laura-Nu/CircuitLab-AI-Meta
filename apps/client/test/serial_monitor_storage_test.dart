import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/features/serial_monitor.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;
import 'serial_readings_test.dart' show TelemetryPort;

/// Only synthetic USB frames; no physical device, API call or Meta response.
void main() {
  for (final language in ['es', 'en']) {
    testWidgets(
      'Serial console restores its offset after collapse in $language',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = AppStrings(language);
        final bucket = PageStorageBucket();
        final api = CircuitApi()..access = 'synthetic-storage-fixture';
        final port = TelemetryPort();
        for (var i = 0; i < 60; i++) {
          port.emit('fixture.log', 'Synthetic observation $i', 'text');
        }
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          api.dispose();
        });
        await tester.pumpWidget(
          shell(
            language,
            PageStorage(
              bucket: bucket,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SerialMonitor(
                    api: api,
                    sessionId: 'console-fixture',
                    canSave: false,
                    onSaved: () async {},
                    serial: port,
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> toggle(String title) async {
          final header = find.text(title);
          await tester.ensureVisible(header);
          await tester.tap(header);
          await tester.pumpAndSettle();
        }

        await toggle(strings.t('serialMonitorTitle'));
        final connect = find.ancestor(
          of: find.text(strings.t('serialConnect')),
          matching: find.bySubtype<OutlinedButton>(),
        );
        await tester.ensureVisible(connect);
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final channels = strings.t('serialAvailableChannels', {'count': 1});
        await toggle(channels);
        await toggle(channels);
        final console = find.byKey(const PageStorageKey('serial-output-scroll'));
        final messages = strings.t('serialRawMessages', {
          'count': port.lines.length,
        });
        expect(console, findsNothing);
        await toggle(messages);
        expect(console, findsOneWidget);
        await tester.ensureVisible(console);
        await tester.drag(console, const Offset(0, -150));
        await tester.pumpAndSettle();
        ScrollPosition position() => tester
            .state<ScrollableState>(
              find
                  .descendant(of: console, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        final previous = position().pixels;
        expect(previous, greaterThan(0));
        await toggle(messages);
        expect(console, findsNothing);
        await toggle(messages);
        expect(console, findsOneWidget);
        expect(position().pixels, closeTo(previous, 1));
        await toggle(strings.t('serialMonitorTitle'));
        expect(console, findsNothing);
        await toggle(strings.t('serialMonitorTitle'));
        expect(console, findsOneWidget);
        expect(position().pixels, closeTo(previous, 1));
        expect(
          find.text(strings.t('serialAvailableChannels', {'count': 1})),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Serial format help restores independently from its selectable example in $language',
      (tester) async {
        final strings = AppStrings(language);
        final api = CircuitApi()..access = 'synthetic-storage-fixture';
        final port = TelemetryPort();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          api.dispose();
        });
        await tester.pumpWidget(
          shell(
            language,
            Scaffold(
              body: SingleChildScrollView(
                child: SerialMonitor(
                  api: api,
                  sessionId: 'format-fixture',
                  canSave: false,
                  onSaved: () async {},
                  serial: port,
                ),
              ),
            ),
          ),
        );
        Future<void> toggle(String title) async {
          final header = find.text(title);
          await tester.ensureVisible(header);
          await tester.tap(header);
          await tester.pumpAndSettle();
        }

        await toggle(strings.t('serialMonitorTitle'));
        final connect = find.ancestor(
          of: find.text(strings.t('serialConnect')),
          matching: find.bySubtype<OutlinedButton>(),
        );
        await tester.ensureVisible(connect);
        await tester.tap(connect);
        await tester.pumpAndSettle();
        await toggle(strings.t('serialFormatTitle'));
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await toggle(strings.t('serialMonitorTitle'));
        await toggle(strings.t('serialMonitorTitle'));
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Serial monitor expansion belongs to its session in $language',
      (tester) async {
        final strings = AppStrings(language);
        final bucket = PageStorageBucket();
        final api = CircuitApi()..access = 'synthetic-storage-fixture';
        final port = TelemetryPort();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          api.dispose();
        });
        Future<void> render(String? sessionId) async {
          await tester.pumpWidget(
            shell(
              language,
              PageStorage(
                bucket: bucket,
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: sessionId == null
                        ? const SizedBox()
                        : SerialMonitor(
                            api: api,
                            sessionId: sessionId,
                            canSave: false,
                            onSaved: () async {},
                            serial: port,
                          ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await render('first-session');
        await tester.tap(find.text(strings.t('serialMonitorTitle')));
        await tester.pumpAndSettle();
        expect(find.text(strings.t('serialConnect')), findsOneWidget);
        await render(null);
        await render('second-session');
        expect(find.text(strings.t('serialConnect')), findsNothing);
        await render(null);
        await render('first-session');
        expect(find.text(strings.t('serialConnect')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
