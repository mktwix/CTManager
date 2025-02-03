import 'package:flutter/foundation.dart';

class LogService extends ChangeNotifier {
  // Singleton implementation
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  final List<String> _logs = [];

  List<String> get logs => List.unmodifiable(_logs);

  void addLog(String message) {
    final timestamp = DateTime.now().toIso8601String();
    _logs.add('[$timestamp] ' + message);
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
} 