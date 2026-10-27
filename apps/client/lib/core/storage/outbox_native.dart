import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'store.dart';

class _Database extends GeneratedDatabase {
  _Database(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement(
        'CREATE TABLE outbox (scope TEXT, id TEXT, payload TEXT NOT NULL, PRIMARY KEY(scope,id))',
      );
      await customStatement(
        'CREATE TABLE drafts (scope TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      );
    },
  );
}

class Outbox implements OfflineStore {
  _Database? _database;
  @override
  bool get supported => true;
  Future<GeneratedDatabase> get db async {
    if (_database != null) return _database!;
    final directory = await getApplicationSupportDirectory();
    return _database = _Database(
      NativeDatabase.createInBackground(
        File('${directory.path}/circuitlab.sqlite'),
      ),
    );
  }

  @override
  Future<void> put(String scope, Map<String, dynamic> item) async {
    await (await db).customStatement(
      'INSERT OR IGNORE INTO outbox VALUES (?, ?, ?)',
      [scope, item['id'], jsonEncode(item)],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> pending(String scope) async {
    final rows = await (await db)
        .customSelect(
          'SELECT payload FROM outbox WHERE scope=? ORDER BY rowid',
          variables: [Variable(scope)],
        )
        .get();
    return rows
        .map(
          (r) => jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
        )
        .toList();
  }

  @override
  Future<void> remove(String scope, String id) async {
    await (await db).customStatement(
      'DELETE FROM outbox WHERE scope=? AND id=?',
      [scope, id],
    );
  }

  @override
  Future<void> saveDraft(String scope, Map<String, dynamic> data) async {
    await (await db).customStatement(
      'INSERT OR REPLACE INTO drafts VALUES (?, ?)',
      [scope, jsonEncode(data)],
    );
  }

  @override
  Future<Map<String, dynamic>?> draft(String scope) async {
    final row = await (await db)
        .customSelect(
          'SELECT payload FROM drafts WHERE scope=?',
          variables: [Variable(scope)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
  }
}
