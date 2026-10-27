import 'package:flutter_test/flutter_test.dart';
import 'package:circuitlab_client/core/networking/api.dart';

void main() {
  test(
    'offline identifiers have sufficient uniqueness and are stable payload keys',
    () {
      final ids = List.generate(1000, (_) => clientId());
      expect(ids.toSet().length, ids.length);
      expect(ids.every((id) => RegExp(r'^[a-f0-9]{40}$').hasMatch(id)), isTrue);
    },
  );
}
