import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/browser_usb.dart';
import 'package:circuitlab_client/core/usb_serial.dart';
import 'layout_test.dart' show TestApi;

/// Synthetic transport fixtures; no physical acquisition or model inference.
class FixtureSerial extends UsbSerialPort {
  int opens = 0, closes = 0, reads = 0;
  Completer<Map<String, dynamic>>? delayed;
  Map<String, dynamic> reading = {
    'status': 'ok',
    'sample_count': 20,
    'value': 2.5,
  };
  @override
  bool get supported => true;
  @override
  Future<Map<String, dynamic>> connect() async {
    opens++;
    return {'status': 'connected'};
  }

  @override
  Future<Map<String, dynamic>> read(Map command, List points) async {
    reads++;
    return delayed == null ? reading : delayed!.future;
  }

  @override
  Future<void> disconnect() async {
    closes++;
    if (delayed != null && !delayed!.isCompleted) {
      delayed!.complete({'status': 'disconnected', 'sample_count': 0});
    }
  }
}

class UsbApi extends TestApi {
  UsbApi() : super(authenticated: true);
  final calls = <String>[];
  Map<String, dynamic>? result;
  bool rejectClaim = false, wrongPoint = false, delivered = false;
  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    calls.add(path);
    if (path.endsWith('/browser/connect')) {
      if (rejectClaim) {
        throw DioException(
          requestOptions: RequestOptions(path: path),
          response: Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 409,
            data: {'code': 'browser_usb_in_use'},
          ),
        );
      }
      return {
        'lease': 'SYNTHETIC-connection-only-credential',
        'points': ['TP1'],
        'calibration_id': 'SYNTHETIC-test-only',
      };
    }
    if (path.endsWith('/browser/poll')) {
      final commands = delivered
          ? []
          : [
              {
                'protocol_version': '1',
                'command_id': 'SYNTHETIC-command',
                'device_id': 'fixture',
                'point_id': wrongPoint ? 'TP9' : 'TP1',
                'action': 'read_voltage',
                'sample_count': 20,
                'deadline_ms': 1000,
              },
            ];
      delivered = true;
      return {
        'commands': commands,
        'server_time': DateTime.now().millisecondsSinceEpoch / 1000,
      };
    }
    if (path.endsWith('/browser/result')) {
      result = Map<String, dynamic>.from(data['result']);
      return {'ack': 'SYNTHETIC-command', 'status': result!['status']};
    }
    return null;
  }
}

class OpeningSerial extends FixtureSerial {
  void Function(String)? stageCallback;
  final opening = Completer<Map<String, dynamic>>();
  @override
  set onState(void Function(String)? callback) {
    stageCallback = callback;
  }

  @override
  Future<Map<String, dynamic>> connect() {
    opens++;
    stageCallback?.call('opening_port');
    return opening.future;
  }
}

class DelayedClaimApi extends UsbApi {
  final firstClaim = Completer<dynamic>();
  bool first = true;
  @override
  Future<dynamic> request(String path, {String method = 'GET', dynamic data}) {
    if (path.endsWith('/browser/connect') && first) {
      first = false;
      calls.add(path);
      return firstClaim.future;
    }
    return super.request(path, method: method, data: data);
  }
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'USB result uses authenticated session delivery and server calibration',
    () async {
      final api = UsbApi(), serial = FixtureSerial();
      final usb = BrowserUsbController(api, serial: serial);
      await usb.connect({'id': 'fixture'});
      await settle();
      expect(serial.opens, 1);
      expect(serial.reads, 1);
      expect(api.result?['point_id'], 'TP1');
      expect(api.result?['value'], 2.5);
      expect(api.result?['calibration_id'], 'SYNTHETIC-test-only');
      expect(api.result?['source'], 'instrumented');
      expect(usb.state, 'connected');
      expect(usb.lastResult, 'ok');
      await usb.disconnect();
      expect(usb.active, isFalse);
      expect(serial.closes, 1);
      usb.dispose();
      await settle();
      api.dispose();
    },
  );
  test(
    'A rejected claim releases USB and preserves the account login',
    () async {
      final api = UsbApi()..rejectClaim = true, serial = FixtureSerial();
      final usb = BrowserUsbController(api, serial: serial);
      await usb.connect({'id': 'fixture'});
      await settle();
      expect(usb.state, 'in_use');
      expect(usb.active, isFalse);
      expect(api.signedIn, isTrue);
      expect(serial.closes, 1);
      expect(serial.reads, 0);
      usb.dispose();
      await settle();
      api.dispose();
    },
  );
  test(
    'Signing out during acquisition prevents submitting a late result',
    () async {
      final api = UsbApi(), serial = FixtureSerial()..delayed = Completer();
      final usb = BrowserUsbController(api, serial: serial);
      await usb.connect({'id': 'fixture'});
      await settle();
      expect(usb.state, 'reading');
      api.access = null;
      api.notifyListeners();
      await settle();
      expect(usb.active, isFalse);
      expect(api.result, isNull);
      expect(serial.closes, greaterThanOrEqualTo(1));
      usb.dispose();
      await settle();
      api.dispose();
    },
  );
  test('An unauthorized point is never passed to the USB adapter', () async {
    final api = UsbApi()..wrongPoint = true, serial = FixtureSerial();
    final usb = BrowserUsbController(api, serial: serial);
    await usb.connect({'id': 'fixture'});
    await settle();
    expect(serial.reads, 0);
    expect(api.result, isNull);
    expect(usb.active, isFalse);
    usb.dispose();
    await settle();
    api.dispose();
  });
  test('A failed acquisition submits no numeric value', () async {
    final api = UsbApi(),
        serial = FixtureSerial()
          ..reading = {'status': 'timeout', 'sample_count': 0};
    final usb = BrowserUsbController(api, serial: serial);
    await usb.connect({'id': 'fixture'});
    await settle();
    expect(api.result?['status'], 'timeout');
    expect(api.result?['value'], isNull);
    expect(usb.lastResult, 'timeout');
    usb.dispose();
    await settle();
    api.dispose();
  });
  test(
    'A selected port reports opening and a terminal timeout without calling the server',
    () async {
      final api = UsbApi(), serial = OpeningSerial();
      final usb = BrowserUsbController(api, serial: serial);
      final attempt = usb.connect({'id': 'fixture'});
      expect(usb.state, 'opening_port');
      expect(usb.connecting, isTrue);
      expect(usb.attemptedDeviceId, 'fixture');
      serial.opening.complete({'status': 'open_timeout'});
      await attempt;
      expect(usb.state, 'open_timeout');
      expect(usb.connecting, isFalse);
      expect(api.calls, isEmpty);
      expect(api.signedIn, isTrue);
      usb.dispose();
      await settle();
      api.dispose();
    },
  );
  test(
    'Cancelling the chooser remains visible instead of returning to idle',
    () async {
      final api = UsbApi(), serial = OpeningSerial();
      final usb = BrowserUsbController(api, serial: serial);
      final attempt = usb.connect({'id': 'fixture'});
      serial.opening.complete({'status': 'cancelled'});
      await attempt;
      expect(usb.state, 'cancelled');
      expect(api.calls, isEmpty);
      usb.dispose();
      await settle();
      api.dispose();
    },
  );
  for (final failOld in [false, true]) {
    test(
      'A late cancelled server claim cannot close a newer USB connection, failure=$failOld',
      () async {
        final api = DelayedClaimApi()..delivered = true,
            serial = FixtureSerial();
        final usb = BrowserUsbController(api, serial: serial);
        final oldAttempt = usb.connect({'id': 'fixture'});
        await settle();
        expect(usb.state, 'registering_server');
        await usb.disconnect(reason: 'cancelled');
        await usb.connect({'id': 'new-device'});
        await settle();
        expect(usb.deviceId, 'new-device');
        expect(serial.closes, 1);
        if (failOld) {
          api.firstClaim.completeError(
            DioException(requestOptions: RequestOptions(path: 'fixture')),
          );
        } else {
          api.firstClaim.complete({
            'lease': 'SYNTHETIC-old-claim',
            'points': ['TP1'],
            'calibration_id': 'fixture',
          });
        }
        await oldAttempt;
        await settle();
        expect(usb.deviceId, 'new-device');
        expect(serial.closes, 1);
        usb.dispose();
        await settle();
        api.dispose();
      },
    );
  }
}
