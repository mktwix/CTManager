// lib/main.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/tunnel_provider.dart';
import 'ui/home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'services/install_cloudflared.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

final Logger logger = Logger(
  printer: PrettyPrinter(),
);

Future<void> initializeApp() async {
  try {
    // Initialize Flutter bindings
    WidgetsFlutterBinding.ensureInitialized();

    // Initialize sqflite for desktop
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    // Set up error handling
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.dumpErrorToConsole(details);
      logger.e('Flutter Error: ${details.exception}', details.exception, details.stack);
    };
  } catch (e, stackTrace) {
    logger.e('Error during initialization', e, stackTrace);
    rethrow;
  }
}

void main() async {
  runZonedGuarded(() async {
    try {
      await initializeApp();
      
      runApp(
        ChangeNotifierProvider(
          create: (_) => TunnelProvider(),
          child: const CloudflaredManagerApp(),
        ),
      );
    } catch (e, stackTrace) {
      logger.e('Fatal error during app startup', e, stackTrace);
      runApp(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Error Starting Application',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    e.toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      exit(1); // This will restart the app
                    },
                    child: const Text('Restart Application'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
    }
  }, (error, stack) {
    logger.e('Uncaught error', error, stack);
  });
}

class CloudflaredManagerApp extends StatefulWidget {
  const CloudflaredManagerApp({super.key});

  @override
  _CloudflaredManagerAppState createState() => _CloudflaredManagerAppState();
}

class _CloudflaredManagerAppState extends State<CloudflaredManagerApp> {
  final InstallCloudflaredService _installService = InstallCloudflaredService();
  final Logger _logger = Logger(
    printer: PrettyPrinter(),
  );
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkAndInstallCloudflared();
    });
  }

  Future<void> checkAndInstallCloudflared() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isFirstRun = prefs.getBool('is_first_run') ?? true;

      if (isFirstRun) {
        bool isInstalled = await _installService.isCloudflaredInstalled();

        if (!isInstalled) {
          if (!mounted) return;
          bool? proceed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Install Cloudflared'),
              content: const Text(
                  'Cloudflared is not installed on your system. Would you like to install the latest version now?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Install'),
                ),
              ],
            ),
          );

          if (proceed == true) {
            if (!mounted) return;
            // Show a loading indicator while downloading
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) => const Center(child: CircularProgressIndicator()),
            );

            String? exePath = await _installService.downloadLatestCloudflared();

            if (!mounted) return;
            Navigator.of(context).pop(); // Remove the loading indicator

            if (exePath != null) {
              // Determine the installation directory
              Directory appData = await getApplicationSupportDirectory();
              String cloudflaredDirPath = p.join(appData.path, 'cloudflared');
              Directory cloudflaredDir = Directory(cloudflaredDirPath);
              if (!await cloudflaredDir.exists()) {
                await cloudflaredDir.create(recursive: true);
              }

              String destinationPath = p.join(cloudflaredDirPath, 'cloudflared.exe');
              File exeFile = File(exePath);
              await exeFile.copy(destinationPath);

              // Add to PATH
              bool pathAdded = await _installService.addToUserPath(cloudflaredDirPath);

              if (pathAdded) {
                if (!mounted) return;
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Installation Complete'),
                    content: const Text(
                        'Cloudflared has been installed and added to your PATH. Please restart your system or log out and log back in for the changes to take effect.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              } else {
                if (!mounted) return;
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Installation Failed'),
                    content: const Text(
                        'Failed to update the system PATH. Please add the installation directory manually or restart your system and try again.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              }
            } else {
              if (!mounted) return;
              await showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Installation Failed'),
                  content: const Text(
                      'Failed to download Cloudflared. Please try again later or install it manually from the official website.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
          }
        } else {
          _logger.i('Cloudflared is already installed.');
        }
        await prefs.setBool('is_first_run', false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloudflared Manager',
      theme: ThemeData(primarySwatch: Colors.blue),
      debugShowCheckedModeBanner: false,
      home: _isInitializing
          ? const Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Initializing...'),
                  ],
                ),
              ),
            )
          : const HomePage(),
    );
  }
}
