// lib/ui/home_page.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tunnel_provider.dart';
import '../models/tunnel.dart';
import '../services/cloudflared_service.dart';
import 'tunnel_form.dart';
import 'dart:io';
import 'package:logger/logger.dart';
import 'create_tunnel_dialog.dart';
import 'tunnel_selection_dialog.dart';
import 'status_dialog.dart';
import 'tunnel_list_item.dart';
import 'logs_page.dart';
import '../services/log_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const cloudflareOrange = Color(0xFFF48120);
const cloudflareBlue = Color(0xFF404242);

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<TunnelProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          backgroundColor: Colors.grey[100],
          appBar: AppBar(
            backgroundColor: cloudflareOrange,
            title: const Text('Cloudflare Tunnel Manager'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _showAddForwardDialog(context),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => provider.checkRunningTunnel(),
              ),
            ],
          ),
          body: provider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : provider.runningTunnel == null
                  ? const Center(
                      child: Text('No running tunnel detected'),
                    )
                  : Column(
                      children: [
                        // Running Tunnel Info
                        Card(
                          margin: const EdgeInsets.all(16),
                          child: ListTile(
                            leading: const Icon(Icons.cloud_done, color: cloudflareOrange),
                            title: Text('Running Tunnel: ${provider.runningTunnel!['name']}'),
                            subtitle: Text('ID: ${provider.runningTunnel!['id']}'),
                          ),
                        ),

                        // Port Forwarding Section
                        Expanded(
                          child: Card(
                            margin: const EdgeInsets.all(16),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Port Forwarding',
                                        style: Theme.of(context).textTheme.titleLarge,
                                      ),
                                      Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.play_arrow),
                                            onPressed: () {
                                              for (var tunnel in provider.tunnels) {
                                                if (!tunnel.isRunning) {
                                                  provider.startForwarding(tunnel.domain, tunnel.port);
                                                }
                                              }
                                            },
                                            tooltip: 'Start All',
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.stop),
                                            onPressed: () {
                                              for (var tunnel in provider.tunnels) {
                                                if (tunnel.isRunning) {
                                                  provider.stopForwarding(tunnel.domain);
                                                }
                                              }
                                            },
                                            tooltip: 'Stop All',
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  // Active Forwards List
                                  Expanded(
                                    child: provider.tunnels.isEmpty
                                        ? const Center(
                                            child: Text('No saved tunnels'),
                                          )
                                        : ListView.builder(
                                            itemCount: provider.tunnels.length,
                                            itemBuilder: (context, index) {
                                              final tunnel = provider.tunnels[index];
                                              return TunnelListItem(
                                                tunnel: tunnel,
                                              );
                                            },
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Logs Section
                        Container(
                          height: 200,
                          margin: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('Logs', style: TextStyle(fontWeight: FontWeight.bold)),
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.copy_outlined, size: 20),
                                          onPressed: () {
                                            final logs = LogService().logs.join('\n');
                                            if (logs.isNotEmpty) {
                                              Clipboard.setData(ClipboardData(text: logs));
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(content: Text('Logs copied to clipboard')),
                                              );
                                            }
                                          },
                                          tooltip: 'Copy all logs',
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, size: 20),
                                          onPressed: () => LogService().clearLogs(),
                                          tooltip: 'Clear logs',
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: AnimatedBuilder(
                                  animation: LogService(),
                                  builder: (context, _) {
                                    final logs = LogService().logs;
                                    return SingleChildScrollView(
                                      child: Padding(
                                        padding: const EdgeInsets.all(8.0),
                                        child: SelectableText(
                                          logs.reversed.join('\n'),
                                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
        );
      },
    );
  }

  void _showAddForwardDialog(BuildContext context) {
    final formKey = GlobalKey<FormState>();
    String domain = '';
    String port = '';
    String protocol = '';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Port Forward'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Domain',
                  hintText: 'e.g., myapp.example.com',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a domain';
                  }
                  return null;
                },
                onSaved: (value) => domain = value!,
              ),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Local Port',
                  hintText: 'e.g., 8080',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a port';
                  }
                  final port = int.tryParse(value);
                  if (port == null || port < 1 || port > 65535) {
                    return 'Please enter a valid port (1-65535)';
                  }
                  return null;
                },
                onSaved: (value) => port = value!,
              ),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Protocol',
                ),
                value: protocol.isEmpty ? 'RDP' : protocol,
                items: const [
                  DropdownMenuItem(value: 'RDP', child: Text('Remote Desktop')),
                  DropdownMenuItem(value: 'SSH', child: Text('SSH')),
                ],
                onChanged: (value) {
                  protocol = value!;
                  // Update port to default value based on protocol
                  if (port.isEmpty || port == '3389' || port == '22') {
                    port = value == 'RDP' ? '3389' : '22';
                  }
                },
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select a protocol';
                  }
                  return null;
                },
                onSaved: (value) => protocol = value!,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                formKey.currentState!.save();
                final tunnel = Tunnel(
                  domain: domain,
                  port: port,
                  protocol: protocol,
                );
                
                await context.read<TunnelProvider>().saveTunnel(tunnel);
                
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Tunnel added successfully'),
                    ),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, Tunnel tunnel) {
    showDialog(
      context: context,
      builder: (context) => TunnelForm(
        tunnel: tunnel,
        isLocal: tunnel.isLocal,
      ),
    );
  }
}
