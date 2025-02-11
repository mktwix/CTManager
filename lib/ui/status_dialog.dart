import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tunnel_provider.dart';
import 'package:logger/logger.dart';
import '../services/cloudflared_service.dart';
import 'package:url_launcher/url_launcher.dart';

class StatusDialog extends StatefulWidget {
  const StatusDialog({super.key});

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  final Logger _logger = Logger();
  bool? _isCloudflaredInstalled;

  @override
  void initState() {
    super.initState();
    _checkCloudflaredStatus();
  }

  Future<void> _checkCloudflaredStatus() async {
    final isInstalled = await CloudflaredService().isCloudflaredInstalled();
    if (mounted) {
      setState(() {
        _isCloudflaredInstalled = isInstalled;
      });
    }
  }

  Future<void> _openCloudflareZeroTrust() async {
    final url = Uri.parse('https://one.dash.cloudflare.com/');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

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
            _isCloudflaredInstalled ?? false,
            _isCloudflaredInstalled == null 
                ? 'Checking...' 
                : _isCloudflaredInstalled! 
                    ? 'Installed' 
                    : 'Not installed - Please install from Cloudflare Zero Trust dashboard',
          ),
          const SizedBox(height: 16),

          // Running Tunnel Status
          if (_isCloudflaredInstalled ?? false) ...[
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
          ] else if (_isCloudflaredInstalled == false) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                'To use this app, you need to:',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Text('1. Go to Cloudflare Zero Trust dashboard'),
            const Text('2. Download and install the Cloudflared agent'),
            const Text('3. Create and run a tunnel'),
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton.icon(
                onPressed: _openCloudflareZeroTrust,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Zero Trust Dashboard'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () async {
            await _checkCloudflaredStatus();
            await tunnelProvider.checkRunningTunnel();
            if (context.mounted) {
              setState(() {});
            }
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