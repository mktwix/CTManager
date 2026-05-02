import 'package:flutter/material.dart';
import '../services/cloudflared_service.dart';

class TunnelSelectionDialog extends StatefulWidget {
  final String protocol;

  const TunnelSelectionDialog({
    super.key,
    required this.protocol,
  });

  @override
  State<TunnelSelectionDialog> createState() => _TunnelSelectionDialogState();
}

class _TunnelSelectionDialogState extends State<TunnelSelectionDialog> {
  final CloudflaredService _cfService = CloudflaredService();
  List<Map<String, String>> _availableTunnels = [];
  bool _isLoading = true;
  final _selectedTunnel = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _loadTunnels();
  }

  @override
  void dispose() {
    _selectedTunnel.dispose();
    super.dispose();
  }

  Future<void> _loadTunnels() async {
    setState(() => _isLoading = true);
    final tunnels = await _cfService.listTunnels();
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
                    onPressed: () => Navigator.of(context).pop('create_new'),
                  ),
                  if (_availableTunnels.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('Or select an existing tunnel:'),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<String?>(
                      valueListenable: _selectedTunnel,
                      builder: (context, selectedId, _) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ..._availableTunnels.map(
                              (tunnel) => ListTile(
                                leading: Radio<String>(
                                  value: tunnel['id']!,
                                  // ignore: deprecated_member_use
                                  groupValue: selectedId,
                                  // ignore: deprecated_member_use
                                  onChanged: (value) =>
                                      _selectedTunnel.value = value,
                                ),
                                title: Text(tunnel['name']!),
                                subtitle: Text(tunnel['url'] ?? 'No URL'),
                                onTap: () =>
                                    _selectedTunnel.value = tunnel['id'],
                              ),
                            ),
                            if (selectedId != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: ElevatedButton(
                                  onPressed: () {
                                    Navigator.of(context).pop({
                                      'type': 'existing',
                                      'tunnelId': selectedId,
                                      'tunnel': _availableTunnels.firstWhere(
                                        (t) => t['id'] == selectedId,
                                      ),
                                    });
                                  },
                                  child: const Text('Use Selected Tunnel'),
                                ),
                              ),
                          ],
                        );
                      },
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