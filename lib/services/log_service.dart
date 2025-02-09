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
    print('LogService: Adding log: $message, category: ${category.name}');
    _logs.add(LogEntry(
      timestamp: DateTime.now(),
      message: message,
      category: category,
    ));
    print('LogService: Total logs after adding: ${_logs.length}');
    notifyListeners();
  }

  void error(String message) => addLog(message, category: LogCategory.error);
  void warning(String message) => addLog(message, category: LogCategory.warning);
  void info(String message) => addLog(message, category: LogCategory.info);
  void system(String message) => addLog(message, category: LogCategory.system);
  void network(String message) => addLog(message, category: LogCategory.network);

  List<LogEntry> getLogsByCategory(LogCategory? category) {
    print('LogService: Getting logs by category: ${category?.name ?? "ALL"}');
    print('LogService: Total logs: ${_logs.length}');
    if (category == null) {
      print('LogService: Returning all logs');
      return List<LogEntry>.from(_logs);
    }
    final filtered = _logs.where((log) => log.category == category).toList();
    print('LogService: Returning ${filtered.length} filtered logs');
    return filtered;
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
} 