import 'package:flutter/material.dart';
import '../services/log_service.dart';

class LogsPage extends StatelessWidget {
  const LogsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final logService = LogService();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Application Logs'),
        actions: [
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
          final logs = logService.logs;
          if (logs.isEmpty) {
            return const Center(child: Text('No logs available'));
          }
          return ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.all(4.0),
                child: Text(logs[index]),
              );
            },
          );
        },
      ),
    );
  }
} 