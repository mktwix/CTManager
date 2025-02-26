import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum LogCategory {
  info,
  error,
  warning,
  system,
  network
}

class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogCategory category;

  LogEntry({
    required this.timestamp,
    required this.message,
    required this.category,
  });

  String get formattedTimestamp => timestamp.toIso8601String();

  @override
  String toString() => '[$formattedTimestamp] ${category.name.toUpperCase()}: $message';

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'message': message,
    'category': category.name,
  };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    timestamp: DateTime.parse(json['timestamp']),
    message: json['message'],
    category: LogCategory.values.firstWhere(
      (e) => e.name == json['category'],
      orElse: () => LogCategory.info,
    ),
  );
}

class LogService extends ChangeNotifier {
  // Singleton implementation
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal() {
    _initLogFile();
  }

  final List<LogEntry> _logs = [];
  File? _logFile;

  Future<void> _initLogFile() async {
    try {
      String appDir;
      if (Platform.isWindows) {
        // Get the executable's directory for portable mode
        appDir = p.dirname(Platform.resolvedExecutable);
      } else {
        // Fallback to AppData for other platforms
        final appDataDir = await getApplicationSupportDirectory();
        appDir = appDataDir.path;
      }
      
      final logDir = Directory(p.join(appDir, 'data'));
      
      // Create log directory if it doesn't exist
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      
      _logFile = File(p.join(logDir.path, 'ctmanager.log'));
      
      // Load existing logs if file exists
      if (await _logFile!.exists()) {
        try {
          final lines = await _logFile!.readAsLines();
          for (var line in lines) {
            _logs.add(LogEntry(
              timestamp: DateTime.now(),
              message: line,
              category: LogCategory.info,
            ));
          }
        } catch (e) {
          print('Error loading logs: $e');
        }
      }
    } catch (e) {
      print('Error initializing log file: $e');
    }
  }

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void addLog(String message, {LogCategory category = LogCategory.info}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: message,
      category: category,
    );
    
    _logs.add(entry);
    _writeLogToFile(entry.toString());
    notifyListeners();
  }

  Future<void> _writeLogToFile(String logMessage) async {
    try {
      if (_logFile != null) {
        await _logFile!.writeAsString('$logMessage\n', mode: FileMode.append);
      }
    } catch (e) {
      print('Error writing to log file: $e');
    }
  }

  void error(String message) => addLog(message, category: LogCategory.error);
  void warning(String message) => addLog(message, category: LogCategory.warning);
  void info(String message) => addLog(message, category: LogCategory.info);
  void system(String message) => addLog(message, category: LogCategory.system);
  void network(String message) => addLog(message, category: LogCategory.network);

  List<LogEntry> getLogsByCategory(LogCategory? category) {
    if (category == null) {
      return List<LogEntry>.from(_logs);
    }
    return _logs.where((log) => log.category == category).toList();
  }

  Future<void> clearLogs() async {
    _logs.clear();
    if (_logFile != null && await _logFile!.exists()) {
      await _logFile!.writeAsString('');
    }
    notifyListeners();
  }
} 