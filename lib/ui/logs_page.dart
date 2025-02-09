import 'package:flutter/material.dart';
import '../services/log_service.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({Key? key}) : super(key: key);

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final LogService logService = LogService();
  LogCategory? _selectedCategory;
  List<LogEntry> _currentLogs = [];

  @override
  void initState() {
    super.initState();
    logService.addListener(_onLogServiceChanged);
    _updateLogs(); // Initialize logs
  }

  void _onLogServiceChanged() {
    print('LogsPage: _onLogServiceChanged called');
    _updateLogs();
  }

  void _updateLogs() {
    print('LogsPage: _updateLogs called with category: $_selectedCategory');
    final filteredLogs = logService.getLogsByCategory(_selectedCategory);
    print('LogsPage: Got ${filteredLogs.length} logs after filtering');
    setState(() {
      _currentLogs = List<LogEntry>.from(filteredLogs);
    });
  }

  void _onCategoryChanged(LogCategory? category) {
    print('LogsPage: Category changed to: ${category?.name ?? "ALL"}');
    _selectedCategory = category;
    _updateLogs();
  }

  @override
  void dispose() {
    logService.removeListener(_onLogServiceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Application Logs'),
        actions: [
          PopupMenuButton<LogCategory?>(
            initialValue: _selectedCategory,
            onSelected: _onCategoryChanged,
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<LogCategory?>(
                value: null,
                child: Text('All'),
              ),
              ...LogCategory.values.map((category) => PopupMenuItem<LogCategory>(
                    value: category,
                    child: Text(category.name.toUpperCase()),
                  )),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  const Icon(Icons.filter_list),
                  const SizedBox(width: 4),
                  Text(_selectedCategory?.name.toUpperCase() ?? 'ALL'),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              logService.clearLogs();
            },
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_currentLogs.isEmpty) {
            return const Center(child: Text('No logs available'));
          }
          return ListView.builder(
            key: ValueKey('logs_${_selectedCategory?.name ?? 'all'}_${_currentLogs.length}'),
            itemCount: _currentLogs.length,
            itemBuilder: (context, index) {
              final log = _currentLogs[index];
              return Padding(
                padding: const EdgeInsets.all(4.0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      log.toString(),
                      style: TextStyle(
                        color: _getColorForCategory(log.category),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Color _getColorForCategory(LogCategory category) {
    switch (category) {
      case LogCategory.error:
        return Colors.red;
      case LogCategory.warning:
        return Colors.orange;
      case LogCategory.info:
        return Colors.blue;
      case LogCategory.system:
        return Colors.purple;
      case LogCategory.network:
        return Colors.green;
    }
  }
} 