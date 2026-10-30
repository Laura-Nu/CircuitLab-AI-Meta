import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/measurement_points.dart';
import 'package:circuitlab_client/core/networking/api.dart';
import 'package:circuitlab_client/core/usb_serial.dart';
import 'package:circuitlab_client/features/serial_monitor.dart';
import 'package:circuitlab_client/l10n/app_strings.dart';
import 'evidence_specification_test.dart' show shell;

/// Synthetic USB/HTTP fixtures: these tests do not claim physical acquisition.
class TelemetryPort extends UsbSerialPort {
  bool active = false;
  int sequence = 0;
  final observations = <Map<String, dynamic>>[];
  final lines = <String>[];

  void emit(String channel, Object value, String unit) {
    final line = jsonEncode({
      'circuitlab': 1, 'channel': channel, 'value': value, 'unit': unit,
    });
    lines.add(line);
    observations.removeWhere((sample) => sample['channel'] == channel);
    observations.add({
      'channel': channel, 'value': value, 'unit': unit, 'line': line,
      'sequence': ++sequence,
      'received_at': DateTime.now().millisecondsSinceEpoch / 1000,
    });
  }

  @override
  bool get supported => true;
  @override
  Future<Map<String, dynamic>> connectMonitor(int baudRate) async {
    active = true;
    return {'status': 'connected'};
  }
  @override
  Map<String, dynamic> monitorSnapshot() => {
    'connected': active, 'sequence': sequence, 'dropped': 0,
    'lines': List<String>.of(lines),
    'observations': List<Map<String, dynamic>>.of(observations),
  };
  @override
  Future<void> disconnect() async { active = false; }
}

Map<String, dynamic> pendingSession({String point = 'TP1', int step = 1}) => {
  'spec_version': 1, 'version': step, 'analysis_steps': step,
  'state': 'awaiting_measurement',
  'pending_test': {'point_id': point, 'requested_at': step},
  'specification': {'points': [
    {'id': 'TP1', 'kind': 'numeric', 'value_kind': 'number',
      'label': 'Temperature', 'unit': '°C', 'min_value': -5, 'max_value': 40},
    {'id': 'TP2', 'kind': 'reported_state', 'value_kind': 'boolean',
      'label': 'GPS fix', 'expected_state': true},
  ]},
};

Future<void> renderMonitor(WidgetTester tester, CircuitApi api, TelemetryPort port,
    Map<String, dynamic> session, Future<void> Function() onSaved,
    {String sessionId = 'synthetic', bool canSave = true}) async {
  await tester.pumpWidget(shell('es', Scaffold(body: SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: SerialMonitor(
      key: const ValueKey('telemetry-fixture'),
      api: api, sessionId: sessionId, session: session, serial: port,
      canSave: canSave, onSaved: onSaved,
    ),
  ))));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> connectMonitor(WidgetTester tester) async {
  final button = find.widgetWithText(OutlinedButton, AppStrings('es').t('serialConnect'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> bindChannel(WidgetTester tester, String point, String channel) async {
  final selector = find.byKey(ValueKey('serial-channel-$point-null'));
  await tester.ensureVisible(selector);
  await tester.tap(selector);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.textContaining(channel).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> enableAutomatic(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('serial-automatic'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> pollMonitor(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() async {
    await (FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
  });

  test('Serial bindings require the actual JSON type and declared unit', () {
    final numeric = {'value_kind': 'number', 'unit': '°C'};
    expect(serialSupportsObservation(numeric, {'value': 0, 'unit': '°C'}), isTrue);
    expect(serialSupportsObservation(numeric, {'value': 23, 'unit': '%'}), isFalse);
    expect(serialSupportsObservation(numeric, {'value': '23', 'unit': '°C'}), isFalse);
    expect(serialSupportsObservation(numeric, {'value': double.nan, 'unit': '°C'}), isFalse);
    expect(serialSupportsObservation({'value_kind': 'boolean'}, {'value': false, 'unit': 'boolean'}), isTrue);
    expect(serialSupportsObservation({'value_kind': 'boolean'}, {'value': 0, 'unit': 'boolean'}), isFalse);
    expect(serialSupportsObservation({'value_kind': 'text'}, {'value': 'FIX', 'unit': 'text'}), isTrue);
    expect(serialSupportsObservation({'value_kind': 'text'}, {'value': true, 'unit': 'text'}), isFalse);
    expect(serialSupportsObservation({'min_v': 0, 'max_v': 5}, {'value': 3300, 'unit': 'mV'}), isTrue);
  });

  testWidgets('Automatic USB records fresh zero and false once per requested check at mobile width', (tester) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = CircuitApi()..access = 'synthetic-ui-fixture';
    final port = TelemetryPort()
      ..emit('dht11.temperature', 23.5, '°C')
      ..emit('dht11.humidity', 48, '%')
      ..emit('gps.fix', false, 'boolean');
    final posts = <Map<String, dynamic>>[];
    var saved = 0;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.method, 'POST');
      expect(options.path, '/sessions/synthetic/serial-readings');
      posts.add(Map<String, dynamic>.from(options.data as Map));
      handler.resolve(Response(requestOptions: options, statusCode: 201, data: {'id': 'synthetic-reading'}));
    }));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    });
    Future<void> onSaved() async { saved++; }
    await renderMonitor(tester, api, port, pendingSession(), onSaved);
    await connectMonitor(tester);
    await bindChannel(tester, 'TP1', 'dht11.temperature');
    await bindChannel(tester, 'TP2', 'gps.fix');
    port.emit('dht11.temperature', 17, '°C'); // Arrives after the last UI poll.
    await enableAutomatic(tester);
    await pollMonitor(tester);
    expect(posts, isEmpty, reason: 'Buffered samples predate explicit automatic acquisition.');
    port.emit('dht11.temperature', 0, '°C');
    await pollMonitor(tester);
    expect(posts, hasLength(1));
    expect(jsonDecode(posts.single['line'] as String)['value'], 0);
    expect(posts.single['point_id'], 'TP1');
    expect(posts.single['conditions_confirmed'], isTrue);
    expect(posts.single['spec_version'], 1);
    expect(saved, 1);
    await pollMonitor(tester);
    expect(posts, hasLength(1));

    port.emit('gps.fix', true, 'boolean'); // Unpolled data predates the next request.
    await renderMonitor(tester, api, port, pendingSession(point: 'TP2', step: 2), onSaved);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('serial-automatic'))).value, isTrue);
    await pollMonitor(tester);
    expect(posts, hasLength(1), reason: 'The earlier GPS sample must not answer a new request.');
    port.emit('gps.fix', false, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(2));
    expect(posts.last['point_id'], 'TP2');
    expect(posts.last['request_version'], 2);
    expect(jsonDecode(posts.last['line'] as String)['value'], isFalse);
    expect(saved, 2);
    await pollMonitor(tester);
    expect(posts, hasLength(2));

    port.emit('gps.fix', true, 'boolean');
    await renderMonitor(tester, api, port, pendingSession(point: 'TP2', step: 3), onSaved);
    await pollMonitor(tester);
    expect(posts, hasLength(2), reason: 'Repeating the same point in a new step requires a new sample.');
    port.emit('gps.fix', false, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(3));
    expect(posts.last['request_version'], 3);
    expect(posts.last['client_id'], isNot(posts[1]['client_id']));

    await renderMonitor(tester, api, port, pendingSession(point: 'TP2', step: 4), onSaved, canSave: false);
    port.emit('gps.fix', true, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(3), reason: 'An active job prevents submissions even before the state changes.');
    final analyzing = pendingSession(point: 'TP2', step: 4)..['state'] = 'analyzing';
    await renderMonitor(tester, api, port, analyzing, onSaved, canSave: false);
    port.emit('gps.fix', false, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(3), reason: 'USB can display data while analysis prevents new submissions.');
    await renderMonitor(tester, api, port, pendingSession(point: 'TP2', step: 4), onSaved);
    await pollMonitor(tester);
    expect(posts, hasLength(3));
    port.emit('gps.fix', true, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(4));
    expect(saved, 4);
    expect(tester.takeException(), isNull);

    await renderMonitor(tester, api, port, pendingSession(), onSaved, sessionId: 'other-session');
    await tester.pump();
    expect(port.active, isFalse, reason: 'Reusing the widget for another session must release its old USB connection.');
    expect(find.byKey(const ValueKey('serial-automatic')), findsNothing);
    expect(posts, hasLength(4));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Verification waits for the acknowledged session version before the next point', (tester) async {
    final api = CircuitApi()..access = 'synthetic-ui-fixture';
    final port = TelemetryPort()
      ..emit('dht11.temperature', 23.5, '°C')
      ..emit('gps.fix', false, 'boolean');
    final posts = <Map<String, dynamic>>[];
    var saved = 0;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      posts.add(Map<String, dynamic>.from(options.data as Map));
      handler.resolve(Response(requestOptions: options, statusCode: 201, data: {'id': 'synthetic-reading'}));
    }));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    });
    final verifying = pendingSession()
      ..['state'] = 'verifying'
      ..['pending_test'] = {'after': 0}
      ..['completion'] = {'missing_points': ['TP1', 'TP2']};
    Future<void> onSaved() async { saved++; } // Simulates a coalesced refresh with no new snapshot yet.
    await renderMonitor(tester, api, port, verifying, onSaved);
    await connectMonitor(tester);
    await bindChannel(tester, 'TP1', 'dht11.temperature');
    await bindChannel(tester, 'TP2', 'gps.fix');
    await enableAutomatic(tester);
    port.emit('dht11.temperature', 0, '°C');
    port.emit('gps.fix', false, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(1));
    expect(posts.single['point_id'], 'TP1');
    expect(saved, 1);
    port.emit('gps.fix', true, 'boolean');
    await pollMonitor(tester);
    expect(posts, hasLength(1), reason: 'The server version is still the version used for the first POST.');
    final refreshed = Map<String, dynamic>.from(verifying)
      ..['version'] = 2
      ..['completion'] = {'missing_points': ['TP2']};
    await renderMonitor(tester, api, port, refreshed, onSaved);
    await pollMonitor(tester);
    expect(posts, hasLength(2));
    expect(posts.last['point_id'], 'TP2');
    expect(posts.last['request_version'], 2);
    expect(saved, 2);
    await pollMonitor(tester);
    expect(posts, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Uncertain USB submission retries the identical payload and client ID', (tester) async {
    final api = CircuitApi()..access = 'synthetic-ui-fixture';
    final port = TelemetryPort()..emit('dht11.temperature', 23.5, '°C');
    final posts = <Map<String, dynamic>>[];
    var saved = 0;
    api.dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      posts.add(Map<String, dynamic>.from(options.data as Map));
      if (posts.length == 1) {
        handler.reject(DioException(requestOptions: options, type: DioExceptionType.receiveTimeout));
      } else {
        handler.resolve(Response(requestOptions: options, statusCode: 201, data: {'id': 'synthetic-reading'}));
      }
    }));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    });
    await renderMonitor(tester, api, port, pendingSession(), () async { saved++; });
    await connectMonitor(tester);
    await bindChannel(tester, 'TP1', 'dht11.temperature');
    await enableAutomatic(tester);
    port.emit('dht11.temperature', 0, '°C');
    await pollMonitor(tester);
    expect(posts, hasLength(1));
    expect(saved, 0);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('serial-automatic'))).value, isFalse);
    await enableAutomatic(tester);
    port.emit('dht11.temperature', 27, '°C');
    await pollMonitor(tester);
    expect(posts, hasLength(2));
    expect(posts.last, equals(posts.first));
    expect(posts.last['client_id'], isNotEmpty);
    expect(saved, 1);
    await pollMonitor(tester);
    expect(posts, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
