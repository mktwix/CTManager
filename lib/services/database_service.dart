// lib/services/database_service.dart

import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import '../models/tunnel.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

final Logger _logger = Logger(
  printer: PrettyPrinter(),
);

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static DatabaseService get instance => _instance;
  DatabaseService._internal();

  Database? _database;
  bool _isInitializing = false;

  Future<void> init() async {
    if (_database != null) return; // Already initialized
    if (_isInitializing) {
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return;
    }

    _isInitializing = true;
    try {
      // Initialize sqflite for FFI
      if (Platform.isWindows || Platform.isLinux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      // Determine the path to the database file
      final Directory appDir = await getApplicationSupportDirectory();
      final String dbPath = p.join(appDir.path, 'ctmanager.db');

      // Ensure the directory exists
      final dbDir = Directory(p.dirname(dbPath));
      if (!await dbDir.exists()) {
        await dbDir.create(recursive: true);
      }

      // Open the database with retry logic
      int retryCount = 0;
      while (retryCount < 3) {
        try {
          _database = await databaseFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(
              version: 2,
              onCreate: _onCreate,
              onUpgrade: _onUpgrade,
            ),
          );
          _logger.i('Database initialized at $dbPath');
          break;
        } catch (e) {
          retryCount++;
          _logger.w('Failed to open database (attempt $retryCount): $e');
          if (retryCount >= 3) {
            throw Exception('Failed to open database after 3 attempts: $e');
          }
          await Future.delayed(Duration(seconds: 1));
        }
      }
    } catch (e) {
      _logger.e('Error initializing database: $e');
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  Database get database {
    if (_database == null) {
      throw StateError('Database not initialized. Call init() first.');
    }
    return _database!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tunnels (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT NOT NULL,
        port TEXT NOT NULL,
        protocol TEXT NOT NULL,
        is_local INTEGER NOT NULL DEFAULT 0,
        is_running INTEGER NOT NULL DEFAULT 0
      )
    ''');
    _logger.i('Tunnels table created with version $version');
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

  Future<void> close() async {
    try {
      if (_database != null) {
        await _database!.close();
        _database = null;
        _logger.i('Database closed');
      }
    } catch (e) {
      _logger.e('Error closing database: $e');
    }
  }

  Future<List<Tunnel>> getSavedTunnels() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('tunnels');
    return List.generate(maps.length, (i) => Tunnel.fromMap(maps[i]));
  }

  Future<void> initDatabase(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tunnels (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT NOT NULL,
        port TEXT NOT NULL,
        protocol TEXT NOT NULL,
        is_local INTEGER NOT NULL DEFAULT 0,
        is_running INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _logger.i('Upgrading database from version $oldVersion to $newVersion');
    
    if (oldVersion < 2) {
      // Add is_running column if upgrading from version 1
      try {
        await db.execute('ALTER TABLE tunnels ADD COLUMN is_running INTEGER NOT NULL DEFAULT 0');
        _logger.i('Added is_running column to tunnels table');
      } catch (e) {
        _logger.e('Error adding is_running column: $e');
        rethrow;
      }
    }
  }

  Future<void> resetDatabase() async {
    try {
      _logger.i('Resetting database...');
      
      // Close existing connection
      await close();
      
      // Get database path
      final Directory appDir = await getApplicationSupportDirectory();
      final String dbPath = p.join(appDir.path, 'ctmanager.db');
      
      // Delete the database file
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        await dbFile.delete();
        _logger.i('Database file deleted');
      }
      
      // Reinitialize the database
      await init();
      _logger.i('Database reset complete');
    } catch (e) {
      _logger.e('Error resetting database: $e');
      rethrow;
    }
  }

  static const _databaseVersion = 2;
}
