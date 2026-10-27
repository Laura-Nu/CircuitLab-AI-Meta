abstract interface class OfflineStore {
  bool get supported;
  Future<void> put(String scope, Map<String, dynamic> item);
  Future<List<Map<String, dynamic>>> pending(String scope);
  Future<void> remove(String scope, String id);
  Future<void> saveDraft(String scope, Map<String, dynamic> data);
  Future<Map<String, dynamic>?> draft(String scope);
}
