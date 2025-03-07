import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import '../models/tunnel.dart';
import '../providers/tunnel_provider.dart';
import 'tunnel_form.dart';

class TunnelListItem extends StatelessWidget {
  final Tunnel tunnel;

  const TunnelListItem({
    super.key,
    required this.tunnel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 0),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(
          tunnel.domain,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Text(
          '${tunnel.protocol} - Port ${tunnel.port}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Start/Stop button
            IconButton(
              icon: Icon(
                tunnel.isRunning ? Icons.stop : Icons.play_arrow,
                color: tunnel.isRunning ? Colors.red : Colors.green,
                size: 20,
              ),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(8),
              onPressed: () {
                final provider = context.read<TunnelProvider>();
                if (tunnel.isRunning) {
                  provider.stopForwarding(tunnel.domain);
                } else {
                  provider.startForwarding(tunnel.domain, tunnel.port);
                }
              },
            ),
            // Open button
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 20),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(8),
              onPressed: () {
                context.read<TunnelProvider>().launchConnection(tunnel);
              },
            ),
            // Edit button
            IconButton(
              icon: const Icon(Icons.edit, size: 20),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(8),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => TunnelForm(tunnel: tunnel),
                );
              },
            ),
            // Delete button
            IconButton(
              icon: const Icon(Icons.delete, size: 20),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(8),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete Tunnel'),
                    content: Text('Are you sure you want to delete ${tunnel.domain}?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          context.read<TunnelProvider>().deleteTunnel(tunnel.id!);
                          Navigator.pop(context);
                        },
                        child: const Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
} 