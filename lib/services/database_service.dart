// lib/services/database_service.dart

import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
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
      
      // Get the database path
      final appDir = await getApplicationDocumentsDirectory();
      final dbPath = join(appDir.path, 'ctmanager.db');
      
      LogService().info('Opening database at $dbPath');
      
      // Open the database
      _database = await openDatabase(
        dbPath,
        version: 2,
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
        auto_select_drive INTEGER DEFAULT 1
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add new columns for drive letter preferences
      await db.execute('ALTER TABLE tunnels ADD COLUMN preferred_drive_letter TEXT');
      await db.execute('ALTER TABLE tunnels ADD COLUMN auto_select_drive INTEGER DEFAULT 1');
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
      
      // Get database path
      final appDir = await getApplicationDocumentsDirectory();
      final dbPath = join(appDir.path, 'ctmanager.db');
      
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
