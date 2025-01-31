import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import '../models/tunnel.dart';
import '../providers/tunnel_provider.dart';

class TunnelListItem extends StatelessWidget {
  final Tunnel tunnel;
  final Function(bool) onToggle;

  const TunnelListItem({
    Key? key,
    required this.tunnel,
    required this.onToggle,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isRunning = context.select<TunnelProvider, bool>(
      (provider) => provider.tunnels.any((t) => t.id == tunnel.id && t.isRunning)
    );

    return ListTile(
      title: Text(tunnel.domain),
      subtitle: Text('Port: ${tunnel.port} · Protocol: ${tunnel.protocol}'),
      trailing: Switch(
        value: isRunning,
        onChanged: (value) => onToggle(value),
      ),
    );
  }
} 