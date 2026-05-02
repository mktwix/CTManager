import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tunnel.dart';
import '../providers/tunnel_provider.dart';
import '../services/smb_service.dart';

import '../main.dart'; // Import main.dart to access the color definitions

class TunnelListItem extends StatelessWidget {
  final Tunnel tunnel;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onLaunch;

  const TunnelListItem({
    super.key,
    required this.tunnel,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onLaunch,
  });

  @override
  Widget build(BuildContext context) {
    final smbService = SmbService();
    final driveLetter = tunnel.protocol == 'SMB' && tunnel.isRunning
        ? smbService.getDriveLetterForDomain(tunnel.domain)
        : null;
    final isProcessing = context
        .watch<TunnelProvider>()
        .processingTunnels
        .contains(tunnel.domain);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
        title: Text(tunnel.domain),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tunnel.protocol} - Port: ${tunnel.port}'),
            if (tunnel.protocol == 'SMB' && driveLetter != null)
              Text('Mounted as $driveLetter:',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        trailing: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Toggle button
            if (isProcessing)
              const SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  ),
                ),
              )
            else
              TextButton.icon(
                icon: Icon(
                  tunnel.isRunning ? Icons.stop_circle : Icons.play_circle,
                  color: tunnel.isRunning ? Colors.red : Colors.green,
                ),
                onPressed: onToggle,
                label: Text(tunnel.isRunning ? 'Stop' : 'Start',
                    style: TextStyle(
                        color: tunnel.isRunning ? Colors.red : Colors.green)),
              ),
            // Launch button (only for running tunnels and non-SMB protocols)
            if (tunnel.isRunning && tunnel.protocol != 'SMB')
              TextButton.icon(
                icon: const Icon(Icons.launch, color: cloudflareBlue),
                onPressed: onLaunch,
                label: const Text('Launch',
                    style: TextStyle(color: cloudflareBlue)),
              ),
            // Open Explorer button (only for running SMB tunnels)
            if (tunnel.isRunning &&
                tunnel.protocol == 'SMB' &&
                driveLetter != null)
              TextButton.icon(
                icon: const Icon(Icons.folder_open, color: cloudflareBlue),
                onPressed: () async {
                  try {
                    await smbService.openDriveInExplorer(driveLetter);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                },
                label: const Text('Explorer',
                    style: TextStyle(color: cloudflareBlue)),
              ),
            // Edit button
            IconButton(
              icon: const Icon(Icons.edit, color: cloudflareOrange),
              onPressed: onEdit,
              tooltip: 'Edit',
            ),
            // Delete button
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: onDelete,
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }
}
