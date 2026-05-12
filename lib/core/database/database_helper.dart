import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';

class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();
  Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    _configurePlatformFactory();
    final basePath = await getDatabasesPath();
    final dbPath = join(basePath, AppConstants.databaseName);
    return openDatabase(
      dbPath,
      version: AppConstants.databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  void _configurePlatformFactory() {
    if (!kIsWeb &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.tableProjectMemory} (
        ${AppConstants.colId}              TEXT    PRIMARY KEY,
        ${AppConstants.colMasterGoal}      TEXT    NOT NULL DEFAULT '',
        ${AppConstants.colCurrentContext}  TEXT    NOT NULL DEFAULT '',
        ${AppConstants.colLastCodeSnippet} TEXT    NOT NULL DEFAULT '',
        ${AppConstants.colTimestamp}       INTEGER NOT NULL
      )
    ''');
    await _createChatHistoryTable(db);
    await _createUserPreferencesTable(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createChatHistoryTable(db);
      await _createUserPreferencesTable(db);
    }
    if (oldVersion < 3) {
      final columns = await db.rawQuery(
        'PRAGMA table_info(${AppConstants.tableChatHistory})',
      );
      final hasAttachmentsColumn = columns.any(
        (column) => column['name'] == AppConstants.colAttachments,
      );
      if (!hasAttachmentsColumn) {
        await db.execute('''
          ALTER TABLE ${AppConstants.tableChatHistory}
          ADD COLUMN ${AppConstants.colAttachments} TEXT DEFAULT '[]'
        ''');
      }
    }
  }

  Future<void> _createChatHistoryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.tableChatHistory} (
        ${AppConstants.colId}        TEXT    PRIMARY KEY,
        ${AppConstants.colSessionId} TEXT    NOT NULL,
        ${AppConstants.colRole}      TEXT    NOT NULL,
        ${AppConstants.colContent}   TEXT    NOT NULL DEFAULT '',
        ${AppConstants.colTimestamp} INTEGER NOT NULL,
        ${AppConstants.colProvider}  TEXT,
        ${AppConstants.colAttachments} TEXT NOT NULL DEFAULT '[]'
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_chat_session
      ON ${AppConstants.tableChatHistory} (${AppConstants.colSessionId}, ${AppConstants.colTimestamp})
    ''');
  }

  Future<void> _createUserPreferencesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.tableUserPreferences} (
        ${AppConstants.colPrefKey}   TEXT PRIMARY KEY,
        ${AppConstants.colPrefValue} TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  // ── project_memory CRUD ─────────────────────────────────────────────────────

  Future<int> insertProjectMemory(Map<String, dynamic> row) async {
    final db = await database;
    return db.insert(AppConstants.tableProjectMemory, row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getAllProjectMemories() async {
    final db = await database;
    return db.query(AppConstants.tableProjectMemory,
        orderBy: '${AppConstants.colTimestamp} DESC');
  }

  Future<Map<String, dynamic>?> getProjectMemoryById(String id) async {
    final db = await database;
    final results = await db.query(AppConstants.tableProjectMemory,
        where: '${AppConstants.colId} = ?', whereArgs: [id], limit: 1);
    return results.isEmpty ? null : results.first;
  }

  Future<Map<String, dynamic>?> getLatestProjectMemory() async {
    final db = await database;
    final results = await db.query(AppConstants.tableProjectMemory,
        orderBy: '${AppConstants.colTimestamp} DESC', limit: 1);
    return results.isEmpty ? null : results.first;
  }

  Future<int> updateProjectMemory(Map<String, dynamic> row) async {
    final db = await database;
    return db.update(AppConstants.tableProjectMemory, row,
        where: '${AppConstants.colId} = ?',
        whereArgs: [row[AppConstants.colId]]);
  }

  Future<int> deleteProjectMemory(String id) async {
    final db = await database;
    return db.delete(AppConstants.tableProjectMemory,
        where: '${AppConstants.colId} = ?', whereArgs: [id]);
  }

  Future<int> deleteAllProjectMemories() async {
    final db = await database;
    return db.delete(AppConstants.tableProjectMemory);
  }

  // ── chat_history CRUD ───────────────────────────────────────────────────────

  Future<void> insertChatMessage(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert(AppConstants.tableChatHistory, row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getChatMessages(String sessionId,
      {int? limit}) async {
    final db = await database;
    return db.query(
      AppConstants.tableChatHistory,
      where: '${AppConstants.colSessionId} = ?',
      whereArgs: [sessionId],
      orderBy: '${AppConstants.colTimestamp} ASC',
      limit: limit,
    );
  }

  Future<int> countChatMessages() async {
    final db = await database;
    final result = await db
        .rawQuery('SELECT COUNT(*) as c FROM ${AppConstants.tableChatHistory}');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<int> deleteOldChatMessages(DateTime cutoff) async {
    final db = await database;
    return db.delete(
      AppConstants.tableChatHistory,
      where: '${AppConstants.colTimestamp} < ?',
      whereArgs: [cutoff.millisecondsSinceEpoch],
    );
  }

  Future<int> deleteChatMessagesBeyondLimit(int maxRows) async {
    final db = await database;
    final count = await countChatMessages();
    if (count <= maxRows) return 0;
    final excess = count - maxRows;
    final result = await db.rawQuery(
      'SELECT ${AppConstants.colId} FROM ${AppConstants.tableChatHistory} '
      'ORDER BY ${AppConstants.colTimestamp} ASC LIMIT ?',
      [excess],
    );
    if (result.isEmpty) return 0;
    final ids = result.map((r) => r[AppConstants.colId] as String).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    return db.delete(
      AppConstants.tableChatHistory,
      where: '${AppConstants.colId} IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Future<int> deleteChatSession(String sessionId) async {
    final db = await database;
    return db.delete(
      AppConstants.tableChatHistory,
      where: '${AppConstants.colSessionId} = ?',
      whereArgs: [sessionId],
    );
  }

  // ── user_preferences CRUD ───────────────────────────────────────────────────

  Future<void> setPreference(String key, String value) async {
    final db = await database;
    await db.insert(
      AppConstants.tableUserPreferences,
      {AppConstants.colPrefKey: key, AppConstants.colPrefValue: value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getPreference(String key) async {
    final db = await database;
    final rows = await db.query(
      AppConstants.tableUserPreferences,
      where: '${AppConstants.colPrefKey} = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first[AppConstants.colPrefValue] as String?;
  }

  Future<Map<String, String>> getAllPreferences() async {
    final db = await database;
    final rows = await db.query(AppConstants.tableUserPreferences);
    return {
      for (final r in rows)
        r[AppConstants.colPrefKey] as String:
            r[AppConstants.colPrefValue] as String,
    };
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
