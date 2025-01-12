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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Logger logger = Logger();
  final CloudflaredService _cfService = CloudflaredService();
  bool _isCloudflaredReady = false;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      setState(() {
        _isInitializing = true;
      });

      // First check cloudflared status
      await checkCloudflaredStatus();

      // Then initialize the tunnel provider
      if (context.mounted) {
        await Provider.of<TunnelProvider>(context, listen: false).loadTunnels();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> checkCloudflaredStatus() async {
    final isLoggedIn = await _cfService.isLoggedIn();
    setState(() {
      _isCloudflaredReady = isLoggedIn;
    });

    if (!isLoggedIn && context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Cloudflared Login Required'),
          content: const Text(
            'You need to login to Cloudflare to use this application. This will open your browser for authentication.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final loginCommand = await _cfService.getLoginCommand();
                if (loginCommand.isNotEmpty) {
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please complete login in your browser')),
                  );
                  // Wait a bit and check login status again
                  await Future.delayed(const Duration(seconds: 10));
                  await checkCloudflaredStatus();
                }
              },
              child: const Text('Login'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tunnelProvider = Provider.of<TunnelProvider>(context);

    // Show loading indicator during initialization
    if (_isInitializing) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Initializing...',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    // Show loading indicator when tunnel provider is loading
    if (tunnelProvider.isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Cloudflared Manager'),
          actions: [
            Icon(
              _isCloudflaredReady ? Icons.check_circle : Icons.warning,
              color: _isCloudflaredReady ? Colors.green : Colors.orange,
            ),
          ],
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflared Manager'),
        actions: [
          IconButton(
            icon: Icon(_isCloudflaredReady ? Icons.check_circle : Icons.warning),
            color: _isCloudflaredReady ? Colors.green : Colors.orange,
            onPressed: () {
              if (!_isCloudflaredReady) {
                checkCloudflaredStatus();
              }
              showDialog(
                context: context,
                builder: (context) => StatusDialog(
                  isCloudflaredReady: _isCloudflaredReady,
                ),
              );
            },
          ),
        ],
      ),
      body: tunnelProvider.tunnels.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_circle_outline, size: 48, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'No tunnels added yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Create a new tunnel or add an existing one',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Create New Tunnel'),
                    onPressed: () => _showCreateTunnelDialog(context),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Or add existing tunnel for:',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.desktop_windows),
                        label: const Text('RDP'),
                        onPressed: () => _showAddTunnelDialog(context, 'RDP'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.terminal),
                        label: const Text('SSH'),
                        onPressed: () => _showAddTunnelDialog(context, 'SSH'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: tunnelProvider.tunnels.length,
              itemBuilder: (context, index) {
                final tunnel = tunnelProvider.tunnels[index];
                return ListTile(
                  leading: Icon(
                    tunnel.isRunning ? Icons.check_circle : Icons.cancel,
                    color: tunnel.isRunning ? Colors.green : Colors.red,
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text('${tunnel.domain}:${tunnel.port} (${tunnel.protocol})'),
                      ),
                      if (tunnel.isLocal)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Local Device',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue,
                            ),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Text(tunnel.isRunning ? 'Running' : 'Stopped'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_arrow, color: Colors.green),
                        onPressed: tunnel.isRunning
                            ? null
                            : () async {
                                final success = await tunnelProvider.startTunnel(tunnel);
                                if (!context.mounted) return;

                                if (!success) {
                                  logger.e('Failed to start tunnel: ${tunnel.domain}');
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Failed to start tunnel: ${tunnel.domain}')),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Started tunnel: ${tunnel.domain}')),
                                  );
                                }
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.stop, color: Colors.red),
                        onPressed: tunnel.isRunning
                            ? () async {
                                final success = await tunnelProvider.stopTunnel(tunnel);
                                if (!context.mounted) return;

                                if (!success) {
                                  logger.e('Failed to stop tunnel: ${tunnel.domain}');
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Failed to stop tunnel: ${tunnel.domain}')),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Stopped tunnel: ${tunnel.domain}')),
                                  );
                                }
                              }
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: tunnel.isRunning
                            ? () {
                                openConnection(tunnel, context);
                              }
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          bool confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Delete Tunnel'),
                                  content: const Text('Are you sure you want to delete this tunnel?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.of(context).pop(true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              ) ??
                              false;

                          if (confirm) {
                            final success = await tunnelProvider.deleteTunnel(tunnel.id!);
                            if (!context.mounted) return;
                            if (success) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Deleted tunnel: ${tunnel.domain}')),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Failed to delete tunnel: ${tunnel.domain}')),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await showDialog<Tunnel>(
            context: context,
            builder: (context) => const TunnelForm(),
          );
          if (result != null) {
            final success = await tunnelProvider.addTunnel(result);
            if (!context.mounted) return;
            if (success) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Added tunnel: ${result.domain}')),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to add tunnel: ${result.domain}')),
              );
            }
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showCreateTunnelDialog(BuildContext context) async {
    // First, show the tunnel selection dialog
    final selection = await showDialog(
      context: context,
      builder: (context) => const TunnelSelectionDialog(),
    );

    if (selection == null) return;

    if (selection == 'create_new') {
      // Create a new tunnel
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => const CreateTunnelDialog(),
      );

      if (result != null && result['success'] && context.mounted) {
        await _handleNewTunnel(context, result);
      }
    } else if (selection is Map) {
      // Use existing tunnel
      final tunnelInfo = selection['tunnel'] as Map<String, String>;
      if (!context.mounted) return;
      await _handleExistingTunnel(context, tunnelInfo);
    }
  }

  Future<void> _handleNewTunnel(BuildContext context, Map<String, dynamic> result) async {
    // Find next available port starting from 4000
    final port = await _cfService.findNextAvailablePort(4000);
    
    // Show success message with the domain for reference
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Created local tunnel: ${result['name']}'),
            const SizedBox(height: 4),
            SelectableText(
              'Domain: ${result['domain']}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text('Port: $port'),
            const Text('Save this domain to connect to this device remotely'),
          ],
        ),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Add Remote Device',
          onPressed: () {
            _showAddTunnelDialog(
              context,
              'RDP',
              initialDomain: result['domain'],
              initialPort: port.toString(),
            );
          },
        ),
      ),
    );
  }

  Future<void> _handleExistingTunnel(BuildContext context, Map<String, String> tunnelInfo) async {
    // Find next available port starting from 4000
    final port = await _cfService.findNextAvailablePort(4000);
    
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Using existing tunnel: ${tunnelInfo['name']}'),
            const SizedBox(height: 4),
            SelectableText(
              'Domain: ${tunnelInfo['url']}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text('Port: $port'),
            const Text('Save this domain to connect to this device remotely'),
          ],
        ),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Add Remote Device',
          onPressed: () {
            _showAddTunnelDialog(
              context,
              'RDP',
              initialDomain: tunnelInfo['url'],
              initialPort: port.toString(),
            );
          },
        ),
      ),
    );
  }

  void _showAddTunnelDialog(BuildContext context, String protocol, {
    String? initialDomain,
    String? initialPort,
  }) async {
    final defaultPort = initialPort ?? (protocol == 'RDP' ? '3389' : '22');
    final result = await showDialog<Tunnel>(
      context: context,
      builder: (context) => TunnelForm(
        initialProtocol: protocol,
        initialPort: defaultPort,
        initialDomain: initialDomain,
        isLocal: false,
      ),
    );
    
    if (result != null && context.mounted) {
      // Find next available port if the chosen one is in use
      int port = int.parse(result.port);
      if (!(await _cfService.checkPortAvailability(port))) {
        port = await _cfService.findNextAvailablePort(4000);
      }

      final tunnelWithPort = Tunnel(
        id: result.id,
        domain: result.domain,
        port: port.toString(),
        protocol: result.protocol,
        isLocal: result.isLocal,
      );

      final success = await Provider.of<TunnelProvider>(context, listen: false)
          .addTunnel(tunnelWithPort);
          
      if (!context.mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added remote device: ${result.domain}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add remote device: ${result.domain}')),
        );
      }
    }
  }

  void openConnection(Tunnel tunnel, BuildContext context) {
    if (tunnel.protocol.toUpperCase() == 'SSH') {
      // For SSH, show a dialog with connection info
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('SSH Connection Info'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('To connect, use this command in your terminal:'),
              const SizedBox(height: 8),
              SelectableText('ssh user@localhost -p ${tunnel.port}'),
              const SizedBox(height: 16),
              const Text('Or click below to open terminal with the command:'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Process.run('powershell', ['-NoExit', '-Command', 'ssh user@localhost -p ${tunnel.port}']);
              },
              child: const Text('Open Terminal'),
            ),
          ],
        ),
      );
    } else if (tunnel.protocol.toUpperCase() == 'RDP') {
      Process.run('mstsc', ['/v:localhost:${tunnel.port}']);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unsupported protocol: ${tunnel.protocol}')),
      );
    }
  }
}
