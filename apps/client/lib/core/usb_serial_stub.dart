class UsbSerialPort {
  bool get supported => false;
  set onDisconnect(void Function()? callback) {}
  set onState(void Function(String)? callback) {}
  Future<Map<String, dynamic>> connect() async => {'status': 'unsupported'};
  Future<Map<String, dynamic>> connectMonitor(int baudRate) async => {'status': 'unsupported'};
  Map<String, dynamic> monitorSnapshot() => {'connected': false, 'lines': <String>[], 'sequence': 0, 'dropped': 0};
  Future<Map<String, dynamic>> read(Map command, List points) async => {
    'status': 'disconnected',
    'sample_count': 0,
  };
  Future<void> disconnect() async {}
}
