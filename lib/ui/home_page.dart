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

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e) {
      logger.e('Error during initialization: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> checkCloudflaredStatus() async {
    final isLoggedIn = await _cfService.isLoggedIn();
    if (mounted) {
      setState(() {
        _isCloudflaredReady = isLoggedIn;
      });
    }

    if (!isLoggedIn && mounted) {
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
                if (loginCommand.isNotEmpty && mounted) {
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
    return Consumer<TunnelProvider>(
      builder: (context, tunnelProvider, child) {
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

        // Main UI
        return Scaffold(
          appBar: AppBar(
            title: const Text('Cloudflared Manager'),
            actions: [
              IconButton(
                icon: Icon(
                  _isCloudflaredReady ? Icons.check_circle : Icons.warning,
                  color: _isCloudflaredReady ? Colors.green : Colors.orange,
                ),
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
              ? _buildEmptyState(context)
              : _buildTunnelList(context, tunnelProvider),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
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
    );
  }

  Widget _buildTunnelList(BuildContext context, TunnelProvider tunnelProvider) {
    return ListView.builder(
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
                icon: const Icon(Icons.play_arrow),
                color: Colors.green,
                onPressed: tunnel.isRunning
                    ? null
                    : () async {
                        final success = await tunnelProvider.startTunnel(tunnel);
                        if (!mounted) return;
                        if (!success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Failed to start tunnel'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                color: Colors.red,
                onPressed: !tunnel.isRunning
                    ? null
                    : () async {
                        final success = await tunnelProvider.stopTunnel(tunnel);
                        if (!mounted) return;
                        if (!success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Failed to stop tunnel'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
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
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true && mounted) {
                    if (tunnel.isRunning) {
                      await tunnelProvider.stopTunnel(tunnel);
                    }
                    final success = await tunnelProvider.deleteTunnel(tunnel.id!);
                    if (!mounted) return;
                    if (!success) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Failed to delete tunnel'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCreateTunnelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const CreateTunnelDialog(),
    );
  }

  void _showAddTunnelDialog(BuildContext context, String protocol) {
    showDialog(
      context: context,
      builder: (context) => TunnelSelectionDialog(protocol: protocol),
    );
  }
}
