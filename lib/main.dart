// lib/main.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:logger/logger.dart';
import 'dart:io';
import 'dart:ffi';
import 'ui/home_page.dart';
import 'providers/tunnel_provider.dart';
import 'services/database_service.dart';
import 'services/log_service.dart';

final logger = Logger();

// Define Cloudflare brand colors
const cloudflareOrange = Color(0xFFF48120);
const cloudflareBlue = Color(0xFF404242);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Check if running as administrator on Windows
    if (Platform.isWindows) {
      final isAdmin = await _isRunningAsAdmin();
      if (!isAdmin) {
        logger.w('App is not running as administrator. Some features may not work properly.');
      }
    }

    // Initialize sqflite_ffi
    if (Platform.isWindows || Platform.isLinux) {
      // Initialize FFI
      sqfliteFfiInit();
      // Change the default factory for Windows/Linux
      databaseFactory = databaseFactoryFfi;
      
      // Set up sqlite3 for Windows
      if (Platform.isWindows) {
        open.overrideFor(OperatingSystem.windows, _openOnWindows);
      }
    }

    // Initialize database
    await DatabaseService.instance.initialize();

    // Perform database read/write test
    final dbTestSuccess = await DatabaseService.instance.testDatabaseReadWrite();
    if (dbTestSuccess) {
      LogService().info('Database test passed.');
    } else {
      LogService().error('Database test failed. Check logs for details.');
    }

    runApp(const MyApp());
  } catch (e) {
    logger.e('Error in main: ${e.toString()}');
    rethrow;
  }
}

Future<bool> _isRunningAsAdmin() async {
  try {
    final result = await Process.run('net', ['session'], runInShell: true);
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

DynamicLibrary _openOnWindows() {
  final scriptDir = File(Platform.resolvedExecutable).parent;
  final libraryNextToScript = File('${scriptDir.path}\\sqlite3.dll');
  return DynamicLibrary.open(libraryNextToScript.path);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (BuildContext context) => TunnelProvider(),
      child: MaterialApp(
        title: 'Cloudflare Tunnel Manager',
        theme: ThemeData(
          primaryColor: cloudflareOrange,
          colorScheme: ColorScheme.fromSwatch().copyWith(
            primary: cloudflareOrange,
            secondary: cloudflareBlue,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: cloudflareOrange,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: cloudflareOrange,
            ),
          ),
          visualDensity: VisualDensity.adaptivePlatformDensity,
        ),
        home: const HomePage(),
      ),
    );
  }
}
