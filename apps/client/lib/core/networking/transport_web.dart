import 'package:dio/dio.dart';
import 'package:dio/browser.dart';

void configureTransport(Dio dio) {
  dio.httpClientAdapter = BrowserHttpClientAdapter(withCredentials: true);
}
