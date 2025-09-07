// lib/services/database_service.dart

import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../services/log_service.dart';
import '../models/tunnel.dart';
import 'package:logger/logger.dart';

final Logger _logger = Logger(
  printer: PrettyPrinter(),
);

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static DatabaseService get instance => _instance;
  
  Database? _database;
  Database get database => _database!;
  
  DatabaseService._internal();
  
  Future<void> initialize() async {
    if (_database != null) return;

    try {
      // Initialize FFI for Windows/Linux
      if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      
      String dbPath;
      if (Platform.isWindows) {
        // For portable mode on Windows, use the executable's directory.
        final exeDir = dirname(Platform.resolvedExecutable);
        final dataDir = Directory(join(exeDir, 'data'));
        if (!await dataDir.exists()) {
          await dataDir.create(recursive: true);
        }
        dbPath = join(dataDir.path, 'ctmanager.db');
      } else {
        // Fallback to documents directory for other platforms.
        final appDir = await getApplicationDocumentsDirectory();
        dbPath = join(appDir.path, 'ctmanager.db');
      }
      
      LogService().info('Opening database at $dbPath');
      
      // Open the database
      _database = await openDatabase(
        dbPath,
        version: 3,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      
      LogService().info('Database opened successfully');
    } catch (e) {
      LogService().error('Error initializing database: $e');
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tunnels (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT NOT NULL,
        port TEXT NOT NULL,
        protocol TEXT NOT NULL,
        username TEXT,
        password TEXT,
        save_credentials INTEGER DEFAULT 0,
        is_local INTEGER DEFAULT 0,
        is_running INTEGER DEFAULT 0,
        preferred_drive_letter TEXT,
        auto_select_drive INTEGER DEFAULT 1,
        remote_path TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add new columns for drive letter preferences
      await db.execute('ALTER TABLE tunnels ADD COLUMN preferred_drive_letter TEXT');
      await db.execute('ALTER TABLE tunnels ADD COLUMN auto_select_drive INTEGER DEFAULT 1');
    }
    if (oldVersion < 3) {
      final tableInfo = await db.rawQuery('PRAGMA table_info(tunnels)');
      final columnExists = tableInfo.any((column) => column['name'] == 'remote_path');
      if (!columnExists) {
        await db.execute('ALTER TABLE tunnels ADD COLUMN remote_path TEXT');
      }
    }
  }

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  Future<int> insertTunnel(Tunnel tunnel) async {
    try {
      return await database.insert('tunnels', tunnel.toMap());
    } catch (e) {
      _logger.e('Error inserting tunnel: $e');
      return -1;
    }
  }

  Future<List<Tunnel>> getTunnels() async {
    try {
      final List<Map<String, dynamic>> maps = await database.query('tunnels');
      return List.generate(maps.length, (i) {
        return Tunnel.fromMap(maps[i]);
      });
    } catch (e) {
      _logger.e('Error fetching tunnels: $e');
      return [];
    }
  }

  Future<int> updateTunnel(Tunnel tunnel) async {
    try {
      return await database.update(
        'tunnels',
        tunnel.toMap(),
        where: 'id = ?',
        whereArgs: [tunnel.id],
      );
    } catch (e) {
      _logger.e('Error updating tunnel: $e');
      return -1;
    }
  }

  Future<int> deleteTunnel(int id) async {
    try {
      return await database.delete(
        'tunnels',
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      _logger.e('Error deleting tunnel: $e');
      return -1;
    }
  }

  Future<bool> testDatabaseReadWrite() async {
    const testTable = 'db_test';
    try {
      LogService().info('Performing database read/write test...');
      
      // 1. Create a test table
      await database.execute('CREATE TABLE $testTable (id INTEGER PRIMARY KEY, name TEXT)');
      LogService().info('Test table "$testTable" created.');

      // 2. Insert a test record
      final testData = {'id': 1, 'name': 'test'};
      await database.insert(testTable, testData);
      LogService().info('Test record inserted.');

      // 3. Read the test record
      final result = await database.query(testTable);
      if (result.isNotEmpty && result.first['name'] == 'test') {
        LogService().info('Test record read successfully.');
      } else {
        throw Exception('Failed to read test record or data mismatch.');
      }

      // 4. Delete the test record
      await database.delete(testTable, where: 'id = ?', whereArgs: [1]);
      LogService().info('Test record deleted.');
      
      // 5. Drop the test table
      await database.execute('DROP TABLE $testTable');
      LogService().info('Test table "$testTable" dropped.');

      LogService().info('Database read/write test successful.');
      return true;

    } catch (e) {
      LogService().error('Database read/write test failed: $e');
      return false;
    }
  }

  Future<List<Tunnel>> getSavedTunnels() async {
    final db = database;
    final List<Map<String, dynamic>> maps = await db.query('tunnels');
    return List.generate(maps.length, (i) => Tunnel.fromMap(maps[i]));
  }

  Future<void> resetDatabase() async {
    try {
      _logger.i('Resetting database...');
      
      // Close existing connection
      await close();
      
      String dbPath;
      if (Platform.isWindows) {
        final exeDir = dirname(Platform.resolvedExecutable);
        final dataDir = Directory(join(exeDir, 'data'));
        dbPath = join(dataDir.path, 'ctmanager.db');
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        dbPath = join(appDir.path, 'ctmanager.db');
      }
      
      // Delete the database file
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        await dbFile.delete();
        _logger.i('Database file deleted');
      }
      
      // Reinitialize the database
      await initialize();
      _logger.i('Database reset complete');
    } catch (e) {
      _logger.e('Error resetting database: $e');
      rethrow;
    }
  }

  static const _databaseVersion = 2;
}
