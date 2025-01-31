import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tunnel_provider.dart';
import 'package:logger/logger.dart';

class StatusDialog extends StatelessWidget {
  final Logger _logger = Logger();

  StatusDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final tunnelProvider = context.watch<TunnelProvider>();

    return AlertDialog(
      title: const Text('Tunnel Status'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cloudflared Status
          _buildStatusRow(
            'Cloudflared',
            !tunnelProvider.isLoading,
            'Checking...',
          ),
          const SizedBox(height: 16),

          // Running Tunnel Status
          _buildStatusRow(
            'Running Tunnel',
            tunnelProvider.runningTunnel != null,
            tunnelProvider.isLoading
                ? 'Checking...'
                : tunnelProvider.runningTunnel?['name'] ?? 'None',
          ),
          const SizedBox(height: 16),

          // Active Port Forwards
          _buildStatusRow(
            'Active Forwards',
            true,
            '${tunnelProvider.forwardingStatus.length}',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () {
            tunnelProvider.checkRunningTunnel();
            _logger.i('Refreshing tunnel status...');
          },
          child: const Text('Refresh'),
        ),
      ],
    );
  }

  Widget _buildStatusRow(String label, bool status, String details) {
    return Row(
      children: [
        Icon(
          status ? Icons.check_circle : Icons.error,
          color: status ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(details, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
} 