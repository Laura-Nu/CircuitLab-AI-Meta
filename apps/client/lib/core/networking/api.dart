import 'dart:convert';
import 'transport_stub.dart' if (dart.library.js_interop) 'transport_web.dart';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../storage/outbox.dart';
import '../storage/store.dart';
import '../../l10n/app_strings.dart';

String clientId() => List.generate(
  20,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class CircuitApi extends ChangeNotifier {
  final Dio dio;
  final DateTime Function() now;
  final OfflineStore outbox;
  final secure = const FlutterSecureStorage();
  String? access;
  String? refresh;
  Future<void>? _renewing;
  DateTime? idleDeadline;
  bool sessionExpired = false;
  bool _activityPending = false;
  DateTime? _lastHumanInput;
  bool _touching = false;
  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);
  bool get canRenew => kIsWeb || refresh != null;

  void recordActivity() {
    if (signedIn && idleDeadline != null && !expireIfIdle()) {
      _activityPending = true;
      _lastHumanInput = now();
    }
  }

  bool expireIfIdle() {
    if (signedIn && idleDeadline != null && !now().isBefore(idleDeadline!)) {
      clearCredentials(expired: true);
      return true;
    }
    return false;
  }

  Future<void> tickSession() async {
    if (expireIfIdle() ||
        !signedIn ||
        idleDeadline == null ||
        !_activityPending ||
        _touching ||
        now().difference(_lastTouch) < const Duration(seconds: 30)) {
      return;
    }
    // Do not replay stale offline input as current activity on reconnection.
    if (_lastHumanInput == null ||
        now().difference(_lastHumanInput!) > const Duration(minutes: 1)) {
      _activityPending = false;
      return;
    }
    _touching = true;
    _activityPending = false;
    try {
      final data = await request('/auth/activity', method: 'POST');
      if (!signedIn) return;
      _setDeadline(data);
      _lastTouch = now();
      await _persistSession();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await clearCredentials(expired: true);
      } else {
        _activityPending = true;
      }
    } finally {
      _touching = false;
    }
  }

  void _setDeadline(dynamic data) {
    if (data is Map && data['idle_expires_at'] is num) {
      idleDeadline = DateTime.fromMillisecondsSinceEpoch(
        ((data['idle_expires_at'] as num) * 1000).round(),
      );
    }
  }

  Future<void> _persistSession() async {
    if (!kIsWeb) {
      await secure.write(key: 'refresh', value: refresh);
      await secure.write(key: 'email', value: email);
    }
  }

  String email = '';
  String language = 'es';
  Map<String, dynamic>? account;
  bool get isAdmin => account?['role'] == 'admin';
  bool get signedIn => access != null;
  String get scope => '${dio.options.baseUrl}|$email';
  CircuitApi({OfflineStore? store, DateTime Function()? clock})
    : now = clock ?? DateTime.now,
      outbox = store ?? Outbox(),
      dio = Dio(
        BaseOptions(
          baseUrl: const String.fromEnvironment(
            'API_BASE_URL',
            defaultValue: 'http://localhost:8000/api/v1',
          ),
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 25),
        ),
      ) {
    configureTransport(dio);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Accept-Language'] = language;
          handler.next(options);
        },
      ),
    );
  }
  Future<void> restore() async {
    if (signedIn) return;
    if (!kIsWeb) {
      email = await secure.read(key: 'email') ?? '';
      refresh = await secure.read(key: 'refresh');
      if (refresh == null) return;
    }
    try {
      await renew();
    } on DioException catch (_) {
      access = null;
    }
  }

  Future<void> register(String mail, String password) async {
    final response = await dio.post(
      '/auth/register',
      data: {
        'email': mail,
        'password': password,
        'client': kIsWeb ? 'web' : 'native',
      },
    );
    await accept(response.data);
  }

  Future<void> login(String mail, String password) async {
    final response = await dio.post(
      '/auth/login',
      data: {
        'email': mail,
        'password': password,
        'client': kIsWeb ? 'web' : 'native',
      },
    );
    email = mail.toLowerCase();
    await accept(response.data);
  }

  Future<void> accept(dynamic data) async {
    access = data['access_token'];
    refresh = data['refresh_token'];
    if (data['user'] is Map) account = Map<String, dynamic>.from(data['user']);
    if (account?['email'] is String) email = account!['email'];
    _setDeadline(data);
    sessionExpired = false;
    _lastTouch = now();
    await _persistSession();
    notifyListeners();
  }

  Future<void> renew() =>
      _renewing ??= _doRenew().whenComplete(() => _renewing = null);

  Future<void> _doRenew() async {
    try {
      final response = await dio.post(
        '/auth/refresh',
        data: kIsWeb ? <String, dynamic>{} : {'refresh_token': refresh},
      );
      await accept(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) await clearCredentials(expired: true);
      rethrow;
    }
  }

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic data,
  }) async {
    try {
      return (await dio.request(
        path,
        data: data,
        options: Options(
          method: method,
          headers: {'Authorization': 'Bearer $access'},
        ),
      )).data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && canRenew) {
        await renew();
        return (await dio.request(
          path,
          data: data,
          options: Options(
            method: method,
            headers: {'Authorization': 'Bearer $access'},
          ),
        )).data;
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    try {
      await request('/auth/logout', method: 'POST');
    } finally {
      await clearCredentials();
    }
  }

  Future<void> clearCredentials({bool expired = false}) async {
    sessionExpired = expired;
    idleDeadline = null;
    _activityPending = false;
    _lastHumanInput = null;
    access = null;
    refresh = null;
    account = null;
    notifyListeners();
    if (!kIsWeb) {
      await secure.delete(key: 'refresh');
      await secure.delete(key: 'email');
    }
  }

  Future<bool> saveMeasurement(
    String sessionId,
    Map<String, dynamic> value,
  ) async {
    final path = '/sessions/$sessionId/measurements';
    try {
      await request(path, method: 'POST', data: value);
      return true;
    } on DioException catch (e) {
      if (e.response != null || !outbox.supported) rethrow;
      await outbox.put(scope, {
        'id': value['client_id'],
        'path': path,
        'data': value,
        'kind': 'measurement',
      });
      return false;
    }
  }

  Future<bool> upload(String sessionId, Uint8List bytes, String name) async {
    final item = {
      'id': clientId(),
      'path': '/sessions/$sessionId/evidence',
      'kind': 'image',
      'bytes': base64Encode(bytes),
      'name': name,
    };
    try {
      await sendImage(item);
      return true;
    } on DioException catch (e) {
      if (e.response != null || !outbox.supported) rethrow;
      await outbox.put(scope, item);
      return false;
    }
  }

  Future<void> sendImage(Map<String, dynamic> item) async {
    FormData body() => FormData.fromMap({
      'client_id': item['id'],
      'file': MultipartFile.fromBytes(
        base64Decode(item['bytes']),
        filename: item['name'],
      ),
    });
    try {
      await dio.post(
        item['path'],
        data: body(),
        options: Options(headers: {'Authorization': 'Bearer $access'}),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != 401 || !canRenew) rethrow;
      await renew();
      await dio.post(
        item['path'],
        data: body(),
        options: Options(headers: {'Authorization': 'Bearer $access'}),
      );
    }
  }

  Future<int> sync() async {
    final items = await outbox.pending(scope);
    for (final item in items) {
      if (item['kind'] == 'image') {
        await sendImage(item);
      } else {
        await request(item['path'], method: 'POST', data: item['data']);
      }
      await outbox.remove(scope, item['id']);
    }
    return items.length;
  }
}

String errorMessage(Object error, {String language = 'es'}) {
  final strings = AppStrings(language);
  if (error is PlatformException || error is MissingPluginException) {
    return strings.t('deviceOperationFailed');
  }
  if (error is DioException) {
    final detail = error.response?.data;
    if (detail is Map && detail['detail'] is String) return detail['detail'];
    if (error.response?.statusCode == 422) {
      return strings.t('checkTheDataAndMeasurementLimits');
    }
    if (error.response == null) {
      return strings.t('cannotConnectToTheApiCheckTheAddress');
    }
    return strings.t('requestFailed', {'status': error.response?.statusCode});
  }
  if (error is StateError && error.message == 'webConnectionRequired') {
    return strings.t('onTheWebYouNeedAConnectionTo');
  }
  return error.toString().replaceFirst('Exception: ', '');
}
