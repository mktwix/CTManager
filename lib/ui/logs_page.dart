import 'package:flutter/material.dart';
import '../services/log_service.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({Key? key}) : super(key: key);

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final LogService logService = LogService();
  LogCategory? selectedCategory;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Application Logs'),
        actions: [
          PopupMenuButton<LogCategory?>(
            initialValue: selectedCategory,
            onSelected: (LogCategory? category) {
              setState(() {
                selectedCategory = category;
              });
            },
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
                  Text(selectedCategory?.name.toUpperCase() ?? 'ALL'),
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
      body: AnimatedBuilder(
        animation: logService,
        builder: (context, child) {
          final logs = logService.getLogsByCategory(selectedCategory);
          if (logs.isEmpty) {
            return const Center(child: Text('No logs available'));
          }
          return ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
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