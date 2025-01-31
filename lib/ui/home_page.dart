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

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tunnelProvider = context.watch<TunnelProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare Tunnel Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => tunnelProvider.checkRunningTunnel(),
          ),
        ],
      ),
      body: tunnelProvider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : tunnelProvider.runningTunnel == null
              ? const Center(
                  child: Text('No running tunnel detected'),
                )
              : Column(
                  children: [
                    // Running Tunnel Info
                    Card(
                      margin: const EdgeInsets.all(16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Running Tunnel',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text('Name: ${tunnelProvider.runningTunnel!['name']}'),
                            Text('ID: ${tunnelProvider.runningTunnel!['id']}'),
                          ],
                        ),
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
                              Text(
                                'Port Forwarding',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              // Active Forwards List
                              Expanded(
                                child: tunnelProvider.forwardingStatus.isEmpty
                                    ? const Center(
                                        child: Text('No active port forwards'),
                                      )
                                    : ListView.builder(
                                        itemCount: tunnelProvider
                                            .forwardingStatus.length,
                                        itemBuilder: (context, index) {
                                          final domain = tunnelProvider
                                              .forwardingStatus.keys
                                              .elementAt(index);
                                          final port = tunnelProvider
                                              .forwardingStatus[domain]!;
                                          return ListTile(
                                            title: Text(domain),
                                            subtitle: Text('Port: $port'),
                                            trailing: IconButton(
                                              icon: const Icon(Icons.stop),
                                              onPressed: () => tunnelProvider
                                                  .stopForwarding(domain),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
      floatingActionButton: tunnelProvider.runningTunnel != null
          ? FloatingActionButton(
              onPressed: () => _showAddForwardDialog(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  void _showAddForwardDialog(BuildContext context) {
    final formKey = GlobalKey<FormState>();
    String domain = '';
    String port = '';

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
                final success = await context
                    .read<TunnelProvider>()
                    .startForwarding(domain, port);
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? 'Port forwarding started'
                          : 'Failed to start port forwarding'),
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
}
