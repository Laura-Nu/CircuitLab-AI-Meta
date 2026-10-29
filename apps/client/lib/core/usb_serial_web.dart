import 'dart:convert';
import 'dart:js_interop';

@JS('circuitLabUsb')
external _SerialApi get _serial;

extension type _SerialApi._(JSObject _) implements JSObject {
  external bool get supported;
  external JSPromise<JSString> connect();
  external JSPromise<JSAny?> disconnect();
  external JSPromise<JSString> read(JSString command, JSString points);
  external set onDisconnect(JSFunction? callback);
}

class UsbSerialPort {
  bool get supported => _serial.supported;
  set onDisconnect(void Function()? callback) {
    _serial.onDisconnect = callback?.toJS;
  }

  Future<Map<String, dynamic>> connect() async => Map<String, dynamic>.from(
    jsonDecode((await _serial.connect().toDart).toDart),
  );
  Future<Map<String, dynamic>> read(Map command, List points) async =>
      Map<String, dynamic>.from(
        jsonDecode(
          (await _serial
                  .read(jsonEncode(command).toJS, jsonEncode(points).toJS)
                  .toDart)
              .toDart,
        ),
      );
  Future<void> disconnect() async {
    await _serial.disconnect().toDart;
  }
}
