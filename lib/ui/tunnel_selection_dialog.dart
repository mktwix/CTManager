import 'package:flutter/material.dart';
import '../services/cloudflared_service.dart';

class TunnelSelectionDialog extends StatefulWidget {
  const TunnelSelectionDialog({super.key});

  @override
  State<TunnelSelectionDialog> createState() => _TunnelSelectionDialogState();
}

class _TunnelSelectionDialogState extends State<TunnelSelectionDialog> {
  final CloudflaredService _cfService = CloudflaredService();
  List<Map<String, String>> _availableTunnels = [];
  bool _isLoading = true;
  String? _selectedTunnelId;

  @override
  void initState() {
    super.initState();
    _loadTunnels();
  }

  Future<void> _loadTunnels() async {
    setState(() {
      _isLoading = true;
    });

    final tunnels = await _cfService.getAvailableTunnels();
    
    setState(() {
      _availableTunnels = tunnels;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Setup Local Tunnel'),
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
                  const Text('Choose how you want to set up your local tunnel:'),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Create New Tunnel'),
                    onPressed: () {
                      Navigator.of(context).pop('create_new');
                    },
                  ),
                  if (_availableTunnels.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('Or select an existing tunnel:'),
                    const SizedBox(height: 8),
                    ...ListTile.divideTiles(
                      context: context,
                      tiles: _availableTunnels.map((tunnel) => RadioListTile<String>(
                        title: Text(tunnel['name']!),
                        subtitle: Text(tunnel['url'] ?? 'No URL'),
                        value: tunnel['id']!,
                        groupValue: _selectedTunnelId,
                        onChanged: (value) {
                          setState(() {
                            _selectedTunnelId = value;
                          });
                        },
                      )),
                    ),
                    if (_selectedTunnelId != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop({
                              'type': 'existing',
                              'tunnelId': _selectedTunnelId,
                              'tunnel': _availableTunnels.firstWhere(
                                (t) => t['id'] == _selectedTunnelId,
                              ),
                            });
                          },
                          child: const Text('Use Selected Tunnel'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
} 