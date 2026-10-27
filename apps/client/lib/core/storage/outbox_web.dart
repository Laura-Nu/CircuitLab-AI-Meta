import 'store.dart';

class Outbox implements OfflineStore {
  final _drafts = <String, Map<String, dynamic>>{};
  @override
  bool get supported => false;
  @override
  Future<void> put(String scope, Map<String, dynamic> item) async {
    throw StateError('webConnectionRequired');
  }

  @override
  Future<List<Map<String, dynamic>>> pending(String scope) async => [];
  @override
  Future<void> remove(String scope, String id) async {}
  @override
  Future<void> saveDraft(String scope, Map<String, dynamic> data) async {
    _drafts[scope] = data;
  }

  @override
  Future<Map<String, dynamic>?> draft(String scope) async => _drafts[scope];
}
