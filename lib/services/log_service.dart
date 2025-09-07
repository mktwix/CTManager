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

  factory LogEntry.fromLogLine(String line) {
    final regex = RegExp(r'^\[(.*?)\]\s(.*?):\s(.*)$');
    final match = regex.firstMatch(line);

    if (match != null && match.groupCount == 3) {
      try {
        final timestamp = DateTime.parse(match.group(1)!);
        final categoryStr = match.group(2)!.toLowerCase();
        final message = match.group(3)!;
        
        final category = LogCategory.values.firstWhere(
          (e) => e.name == categoryStr,
          orElse: () => LogCategory.info,
        );

        return LogEntry(
          timestamp: timestamp,
          message: message,
          category: category,
        );
      } catch (e) {
        // Fallback for parsing errors
        return LogEntry(timestamp: DateTime.now(), message: line, category: LogCategory.system);
      }
    }
    // Fallback for lines that don't match the format
    return LogEntry(timestamp: DateTime.now(), message: line, category: LogCategory.system);
  }
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
            if (line.isNotEmpty) {
              _logs.add(LogEntry.fromLogLine(line));
            }
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