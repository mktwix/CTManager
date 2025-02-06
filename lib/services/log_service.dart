import 'package:flutter/foundation.dart';

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
}

class LogService extends ChangeNotifier {
  // Singleton implementation
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  final List<LogEntry> _logs = [];

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void addLog(String message, {LogCategory category = LogCategory.info}) {
    _logs.add(LogEntry(
      timestamp: DateTime.now(),
      message: message,
      category: category,
    ));
    notifyListeners();
  }

  void error(String message) => addLog(message, category: LogCategory.error);
  void warning(String message) => addLog(message, category: LogCategory.warning);
  void info(String message) => addLog(message, category: LogCategory.info);
  void system(String message) => addLog(message, category: LogCategory.system);
  void network(String message) => addLog(message, category: LogCategory.network);

  List<LogEntry> getLogsByCategory(LogCategory? category) {
    if (category == null) return logs;
    return logs.where((log) => log.category == category).toList();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
} 