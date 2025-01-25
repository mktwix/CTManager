import 'package:flutter/material.dart';
import '../services/cloudflared_service.dart';
import '../providers/tunnel_provider.dart';
import 'package:provider/provider.dart';

class StatusDialog extends StatefulWidget {
  final bool isCloudflaredReady;
  const StatusDialog({super.key, required this.isCloudflaredReady});

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  final CloudflaredService _cfService = CloudflaredService();
  List<Map<String, String>> _availableTunnels = [];
  bool _isLoading = true;
  Map<String, bool> _portStatus = {};
  Map<String, dynamic>? _localTunnel;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _isLoading = true;
    });

    // Get all tunnels from Cloudflare account
    final tunnels = await _cfService.getAvailableTunnels();
    
    // Get local tunnel info
    final localTunnel = await _cfService.getLocalTunnelInfo();
    
    // Check port availability
    final ports = <int>[];
    for (int port = 4000; port < 4020; port++) { // Check first 20 ports in our range
      ports.add(port);
    }
    
    Map<String, bool> portStatus = {};
    for (int port in ports) {
      portStatus[port.toString()] = await _cfService.checkPortAvailability(port);
    }

    if (mounted) {
      setState(() {
        _availableTunnels = tunnels;
        _localTunnel = localTunnel;
        _portStatus = portStatus;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tunnelProvider = Provider.of<TunnelProvider>(context);
    
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.isCloudflaredReady ? Icons.check_circle : Icons.warning,
            color: widget.isCloudflaredReady ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          const Text('System Status'),
        ],
      ),
      content: _isLoading
          ? const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cloudflared Status
                  _buildSection(
                    'Cloudflared Status',
                    [
                      _buildStatusItem(
                        'Service',
                        widget.isCloudflaredReady ? 'Running' : 'Not Ready',
                        widget.isCloudflaredReady,
                      ),
                      _buildStatusItem(
                        'Login Status',
                        widget.isCloudflaredReady ? 'Logged In' : 'Not Logged In',
                        widget.isCloudflaredReady,
                      ),
                    ],
                  ),
                  const Divider(),
                  // Local Tunnel Info
                  _buildSection(
                    'Local Device Tunnel',
                    [
                      if (_localTunnel != null) ...[
                        _buildStatusItem(
                          'Name',
                          _localTunnel!['name']!,
                          true,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.link,
                                size: 16,
                                color: Colors.blue,
                              ),
                              const SizedBox(width: 8),
                              const Text('Domain'),
                              const Spacer(),
                              SelectableText(
                                _localTunnel!['domain']!,
                                style: const TextStyle(
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if ((_localTunnel!['ingress_rules'] as List).isNotEmpty) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Configured Hostnames:',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ...(_localTunnel!['ingress_rules'] as List).map((rule) {
                            final hostname = rule['hostname'] as String;
                            final service = rule['service'] as String;
                            final isLocalService = service.contains('localhost') || 
                                                 service.contains('127.0.0.1');
                            return Padding(
                              padding: const EdgeInsets.only(left: 8, top: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    isLocalService ? Icons.computer : Icons.cloud,
                                    size: 16,
                                    color: isLocalService ? Colors.green : Colors.grey,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SelectableText(
                                          hostname,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        Text(
                                          service,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ],
                      ] else
                        _buildStatusItem(
                          'Status',
                          'No local tunnel configured',
                          false,
                        ),
                    ],
                  ),
                  const Divider(),
                  // Tunnels Status
                  _buildSection(
                    'Tunnels',
                    [
                      _buildStatusItem(
                        'Available Tunnels',
                        '${_availableTunnels.length}',
                        _availableTunnels.isNotEmpty,
                      ),
                      _buildStatusItem(
                        'Active Local Tunnels',
                        '${tunnelProvider.tunnels.where((t) => t.isRunning).length}',
                        true,
                      ),
                    ],
                  ),
                  const Divider(),
                  // Port Status
                  _buildSection(
                    'Port Status',
                    [
                      const Text('Available Ports (4000+):'),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _portStatus.entries
                            .where((e) => int.parse(e.key) >= 4000)
                            .map((e) => Chip(
                                  label: Text(e.key),
                                  backgroundColor: e.value
                                      ? Colors.green.withOpacity(0.1)
                                      : Colors.red.withOpacity(0.1),
                                  labelStyle: TextStyle(
                                    color: e.value ? Colors.green : Colors.red,
                                  ),
                                ))
                            .toList(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: _loadStatus,
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _buildStatusItem(String label, String value, bool isPositive) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            isPositive ? Icons.check_circle : Icons.error,
            size: 16,
            color: isPositive ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Text(label),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: isPositive ? Colors.green : Colors.orange,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
} 