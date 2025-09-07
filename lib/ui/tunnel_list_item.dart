import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tunnel.dart';
import '../providers/tunnel_provider.dart';
import '../services/smb_service.dart';
import 'dart:io';
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
    final isProcessing =
        context.watch<TunnelProvider>().processingTunnels.contains(tunnel.domain);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
        title: Text(tunnel.domain),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tunnel.protocol} - Port: ${tunnel.port}'),
            if (tunnel.protocol == 'SMB' && driveLetter != null)
              Text('Mounted as $driveLetter:', style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
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
              IconButton(
                icon: Icon(
                  tunnel.isRunning ? Icons.stop_circle : Icons.play_circle,
                  color: tunnel.isRunning ? Colors.red : Colors.green,
                ),
                onPressed: onToggle,
                tooltip: tunnel.isRunning ? 'Stop' : 'Start',
              ),
            // Launch button (only for running tunnels and non-SMB protocols)
            if (tunnel.isRunning && tunnel.protocol != 'SMB')
              IconButton(
                icon: const Icon(Icons.launch, color: cloudflareBlue),
                onPressed: onLaunch,
                tooltip: 'Launch',
              ),
            // Open Explorer button (only for running SMB tunnels)
            if (tunnel.isRunning && tunnel.protocol == 'SMB' && driveLetter != null)
              IconButton(
                icon: const Icon(Icons.folder_open, color: cloudflareBlue),
                onPressed: () {
                  // Open Windows Explorer to the mounted drive
                  Process.run('explorer.exe', ['$driveLetter:'], runInShell: true);
                },
                tooltip: 'Open in Explorer',
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