class UsbSerialPort {
  bool get supported => false;
  set onDisconnect(void Function()? callback) {}
  Future<Map<String, dynamic>> connect() async => {'status': 'unsupported'};
  Future<Map<String, dynamic>> read(Map command, List points) async => {
    'status': 'disconnected',
    'sample_count': 0,
  };
  Future<void> disconnect() async {}
}
