import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'networking/api.dart';
import 'usb_serial.dart';

/// One account-scoped USB connection for the lifetime of the app, across session routes.
class BrowserUsbController extends ChangeNotifier {
  final CircuitApi api;
  final UsbSerialPort port;
  String state = 'idle', lastResult = '';
  String? deviceId, attemptedDeviceId, _lease;
  List<dynamic> _points = [];
  String _calibration = '';
  Timer? _timer;
  bool _disposed = false;
  int? _pollGeneration;
  int _generation = 0;

  BrowserUsbController(this.api, {UsbSerialPort? serial})
    : port = serial ?? UsbSerialPort() {
    port.onDisconnect = () => unawaited(disconnect(reason: 'disconnected'));
    port.onState = (stage) {
      if (connecting &&
          const {
            'choosing_port',
            'opening_port',
            'starting_instrument',
          }.contains(stage)) {
        state = stage;
        _changed();
      }
    };
    api.addListener(_authChanged);
  }
  bool get supported => port.supported;
  bool get active => deviceId != null;
  bool get connecting => const {
    'connecting',
    'choosing_port',
    'opening_port',
    'starting_instrument',
    'registering_server',
  }.contains(state);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _authChanged() {
    if (!api.signedIn && (active || connecting || port.monitorSnapshot()['connected'] == true)) {
      unawaited(disconnect());
    }
  }

  Future<void> connect(Map device) async {
    if (_disposed || active || connecting || !api.signedIn) return;
    final generation = ++_generation;
    attemptedDeviceId = device['id'];
    state = 'choosing_port';
    lastResult = '';
    _changed();
    try {
      // The permission prompt starts here, before the first awaited server operation.
      final opened = await port.connect();
      if (generation != _generation) return;
      if (!api.signedIn) {
        await disconnect(reason: 'signed_out');
        return;
      }
      if (opened['status'] != 'connected') {
        state = opened['status'] as String;
        _changed();
        return;
      }
      state = 'registering_server';
      _changed();
      final response = await api
          .request('/devices/${device['id']}/browser/connect', method: 'POST')
          .timeout(const Duration(seconds: 12));
      if (generation != _generation || !api.signedIn) {
        unawaited(
          api
              .request(
                '/devices/${device['id']}/browser/disconnect',
                method: 'POST',
                data: {'lease': response['lease']},
              )
              .catchError((_) => null),
        );
        return;
      }
      deviceId = device['id'];
      _lease = response['lease'];
      _points = response['points'] as List;
      _calibration = response['calibration_id'];
      state = 'connected';
      _changed();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
      unawaited(poll());
    } catch (error) {
      if (generation == _generation) await disconnect(reason: _reason(error));
    }
  }

  String _reason(Object error) {
    if (error is TimeoutException) return 'server_timeout';
    if (error is DioException) {
      if (error.response?.statusCode == 401) return 'signed_out';
      final code = error.response?.data is Map
          ? error.response?.data['code']
          : null;
      if (code == 'browser_usb_in_use') return 'in_use';
      if (code == 'browser_usb_expired') return 'expired';
      if (error.response?.statusCode == 404) return 'backend_update';
    }
    return 'connection_error';
  }

  Future<void> poll() async {
    if (_disposed || _pollGeneration == _generation || !active) return;
    if (!api.signedIn) {
      await disconnect(reason: 'signed_out');
      return;
    }
    _pollGeneration = _generation;
    final generation = _generation, id = deviceId!, lease = _lease!;
    try {
      final response = await api.request(
        '/devices/$id/browser/poll',
        method: 'POST',
        data: {'lease': lease},
      );
      final clock = Stopwatch()..start();
      for (final command in response['commands'] as List) {
        if (generation != _generation || !api.signedIn) break;
        if (command['device_id'] != id ||
            !_points.contains(command['point_id'])) {
          throw StateError('Unauthorized instrument channel');
        }
        state = 'reading';
        _changed();
        final reading = await port.read(
          Map<String, dynamic>.from(command),
          _points,
        );
        if (generation != _generation || !api.signedIn) break;
        final result = {
          'protocol_version': '1',
          'command_id': command['command_id'],
          'point_id': command['point_id'],
          'status': reading['status'],
          'sample_count': reading['sample_count'],
          'value': reading['status'] == 'ok' ? reading['value'] : null,
          'unit': command['action'] == 'read_digital' ? 'boolean' : 'V',
          'source': 'instrumented',
          'calibration_id': _calibration,
          'measured_at':
              (response['server_time'] as num) +
              clock.elapsedMilliseconds / 1000,
        };
        final ack = await api.request(
          '/devices/$id/browser/result',
          method: 'POST',
          data: {'lease': lease, 'result': result},
        );
        lastResult = ack['status'] == 'timeout'
            ? 'timeout'
            : reading['status'] as String;
        if (reading['status'] == 'disconnected') {
          await disconnect(reason: 'disconnected');
          break;
        }
      }
      if (generation == _generation && active && state != 'connected') {
        state = 'connected';
        _changed();
      }
    } catch (error) {
      if (generation == _generation) await disconnect(reason: _reason(error));
    } finally {
      if (_pollGeneration == generation) _pollGeneration = null;
    }
  }

  Future<void> disconnect({String reason = 'idle'}) async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final id = deviceId, lease = _lease;
    deviceId = null;
    _lease = null;
    state = reason;
    _changed();
    await port.disconnect();
    if (id != null && lease != null && api.signedIn) {
      try {
        await api
            .request(
              '/devices/$id/browser/disconnect',
              method: 'POST',
              data: {'lease': lease},
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    api.removeListener(_authChanged);
    port.onDisconnect = null;
    port.onState = null;
    unawaited(disconnect());
    super.dispose();
  }
}
