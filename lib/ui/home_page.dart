// lib/ui/home_page.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tunnel_provider.dart';
import '../models/tunnel.dart';
import 'tunnel_form.dart';
import 'tunnel_list_item.dart';
import '../services/log_service.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../ui/smb_auth_dialog.dart';
import '../services/smb_service.dart';
import '../services/smb_exceptions.dart';
import '../main.dart';  // Import main.dart to access the color definitions

// Using colors defined in main.dart
// const cloudflareOrange = Color(0xFFF48120);
// const cloudflareBlue = Color(0xFF404242);

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LogCategory? _selectedCategory;

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
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh UI and check tunnel status',
                onPressed: () => provider.checkRunningTunnel(),
              ),
            ],
          ),
          body: provider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : provider.runningTunnel == null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'No running tunnel detected',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'To use this app, you need to:',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          const Text('1. Go to Cloudflare Zero Trust dashboard'),
                          const Text('2. Download and install the Cloudflared agent'),
                          const Text('3. Create and run a tunnel'),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final url = Uri.parse('https://one.dash.cloudflare.com/');
                              if (await canLaunchUrl(url)) {
                                await launchUrl(url);
                              }
                            },
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open Zero Trust Dashboard'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: cloudflareOrange,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        // Running Tunnel Info
                        Card(
                          margin: const EdgeInsets.all(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).primaryColor.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.cloud_done_rounded,
                                    color: Theme.of(context).primaryColor,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            provider.runningTunnel!['name'] ?? 'Unnamed Tunnel',
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (provider.runningTunnel!['requires_login'] == 'true') ...[
                                            const SizedBox(width: 8),
                                            TextButton.icon(
                                              onPressed: () async {
                                                await provider.initiateLogin();
                                                await provider.checkRunningTunnel();
                                              },
                                              icon: const Icon(Icons.login, size: 16),
                                              label: const Text('Login'),
                                              style: TextButton.styleFrom(
                                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                                backgroundColor: Colors.grey[100],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'ID: ${provider.runningTunnel!['id']}',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Main content row containing Port Forwarding and Logs
                        Expanded(
                          child: Row(
                            children: [
                              // Port Forwarding Section
                              Expanded(
                                flex: 1,
                                child: Card(
                                  margin: const EdgeInsets.only(left: 16, right: 8, bottom: 16),
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
                                                // Export button
                                                IconButton(
                                                  icon: Icon(Icons.upload_outlined,
                                                    color: Theme.of(context).primaryColor,
                                                    size: 24,
                                                  ),
                                                  onPressed: () => _handleExport(context),
                                                  tooltip: 'Export Tunnels',
                                                ),
                                                // Import button
                                                IconButton(
                                                  icon: Icon(Icons.download_outlined,
                                                    color: Theme.of(context).primaryColor,
                                                    size: 24,
                                                  ),
                                                  onPressed: () => _handleImport(context),
                                                  tooltip: 'Import Tunnels',
                                                ),
                                                IconButton(
                                                  icon: Icon(Icons.add_circle_outline, 
                                                    color: Theme.of(context).primaryColor,
                                                    size: 28,
                                                  ),
                                                  onPressed: () => _showAddForwardDialog(context),
                                                  tooltip: 'Add Port Forward',
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.grey[100],
                                                    borderRadius: BorderRadius.circular(20),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      IconButton(
                                                        icon: Icon(Icons.play_arrow_rounded,
                                                          color: Colors.grey[700],
                                                        ),
                                                        onPressed: () {
                                                          for (var tunnel in provider.tunnels) {
                                                            _toggleTunnel(tunnel);
                                                          }
                                                        },
                                                        tooltip: 'Start All',
                                                      ),
                                                      IconButton(
                                                        icon: Icon(Icons.stop_rounded,
                                                          color: Colors.grey[700],
                                                        ),
                                                        onPressed: () {
                                                          for (var tunnel in provider.tunnels) {
                                                            _toggleTunnel(tunnel);
                                                          }
                                                        },
                                                        tooltip: 'Stop All',
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 16),
                                        // Active Forwards List
                                        Expanded(
                                          child: provider.tunnels.isEmpty
                                              ? Center(
                                                  child: Column(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      Icon(Icons.cloud_off_outlined, 
                                                        size: 48, 
                                                        color: Colors.grey[400],
                                                      ),
                                                      const SizedBox(height: 16),
                                                      Text(
                                                        'No saved tunnels',
                                                        style: TextStyle(
                                                          color: Colors.grey[600],
                                                          fontSize: 16,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                )
                                              : ListView.builder(
                                                  itemCount: provider.tunnels.length,
                                                  itemBuilder: (context, index) {
                                                    final tunnel = provider.tunnels[index];
                                                    return TunnelListItem(
                                                      tunnel: tunnel,
                                                      onToggle: () => _toggleTunnel(tunnel),
                                                      onEdit: () => _showEditDialog(context, tunnel),
                                                      onDelete: () => _showDeleteDialog(context, tunnel),
                                                      onLaunch: () => provider.launchConnection(tunnel),
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
                              Expanded(
                                flex: 1,
                                child: Card(
                                  margin: const EdgeInsets.only(left: 8, right: 16, bottom: 16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[50],
                                          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                        ),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(
                                                  Icons.article_outlined,
                                                  size: 20,
                                                  color: Colors.grey[700],
                                                ),
                                                const SizedBox(width: 8),
                                                const Text(
                                                  'Logs',
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                DropdownButton<LogCategory?>(
                                                  value: _selectedCategory,
                                                  hint: const Text('All Categories'),
                                                  items: [
                                                    const DropdownMenuItem<LogCategory?>(
                                                      value: null,
                                                      child: Text('All Categories'),
                                                    ),
                                                    ...LogCategory.values.map((category) {
                                                      return DropdownMenuItem<LogCategory?>(
                                                        value: category,
                                                        child: Text(category.name.toUpperCase()),
                                                      );
                                                    }).toList(),
                                                  ],
                                                  onChanged: (LogCategory? value) {
                                                    setState(() {
                                                      _selectedCategory = value;
                                                    });
                                                  },
                                                ),
                                              ],
                                            ),
                                            Row(
                                              children: [
                                                IconButton(
                                                  icon: Icon(
                                                    Icons.copy_outlined,
                                                    size: 20,
                                                    color: Colors.grey[700],
                                                  ),
                                                  onPressed: () {
                                                    final logs = LogService().getLogsByCategory(_selectedCategory).map((log) => log.toString()).join('\n');
                                                    if (logs.isNotEmpty) {
                                                      Clipboard.setData(ClipboardData(text: logs));
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        const SnackBar(
                                                          content: Text('Logs copied to clipboard'),
                                                          duration: Duration(seconds: 2),
                                                        ),
                                                      );
                                                    }
                                                  },
                                                  tooltip: 'Copy logs',
                                                ),
                                                IconButton(
                                                  icon: Icon(
                                                    Icons.delete_outline_rounded,
                                                    size: 20,
                                                    color: Colors.grey[700],
                                                  ),
                                                  onPressed: () => LogService().clearLogs(),
                                                  tooltip: 'Clear logs',
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        child: ValueListenableBuilder<LogCategory?>(
                                          valueListenable: ValueNotifier(_selectedCategory),
                                          builder: (context, category, _) {
                                            return AnimatedBuilder(
                                              animation: LogService(),
                                              builder: (context, _) {
                                                final logs = LogService().getLogsByCategory(category);
                                                return Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.grey[50],
                                                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                                                  ),
                                                  child: SingleChildScrollView(
                                                    padding: const EdgeInsets.all(16),
                                                    child: SelectableText(
                                                      logs.reversed.map((log) => log.toString()).join('\n'),
                                                      style: TextStyle(
                                                        fontFamily: 'monospace',
                                                        fontSize: 12,
                                                        color: Colors.grey[800],
                                                        height: 1.5,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
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
    String protocol = 'RDP';

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
                value: protocol,
                items: const [
                  DropdownMenuItem(value: 'RDP', child: Text('Remote Desktop')),
                  DropdownMenuItem(value: 'SSH', child: Text('SSH')),
                  DropdownMenuItem(value: 'SMB', child: Text('SMB File Share')),
                ],
                onChanged: (value) {
                  protocol = value!;
                  // Update port to default value based on protocol
                  if (port.isEmpty || port == '3389' || port == '22' || port == '445') {
                    port = value == 'RDP' ? '3389' : (value == 'SSH' ? '22' : '445');
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
                    const SnackBar(
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

  void _showDeleteDialog(BuildContext context, Tunnel tunnel) {
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
  }

  Future<void> _handleExport(BuildContext context) async {
    try {
      final provider = context.read<TunnelProvider>();
      final jsonData = provider.exportTunnels();
      
      // Get the save path from user
      String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Tunnels Configuration',
        fileName: 'tunnels_config.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (savePath != null) {
        // Ensure .json extension
        if (!savePath.toLowerCase().endsWith('.json')) {
          savePath = '$savePath.json';
        }
        
        // Write the JSON data to file
        await File(savePath).writeAsString(jsonData);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tunnels exported successfully')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export tunnels: $e')),
        );
      }
    }
  }

  Future<void> _handleImport(BuildContext context) async {
    try {
      // Get the file path from user
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        // Read the JSON data from file
        final jsonStr = await File(result.files.single.path!).readAsString();
        
        // Import the tunnels
        await context.read<TunnelProvider>().importTunnels(jsonStr);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tunnels imported successfully')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import tunnels: $e')),
        );
      }
    }
  }

  Future<void> _toggleTunnel(Tunnel tunnel) async {
    final provider = context.read<TunnelProvider>();
    
    if (tunnel.isRunning) {
      // Stop the tunnel
      await provider.stopForwarding(tunnel.domain);
    } else {
      try {
        // For SMB tunnels, show authentication dialog if needed
        if (tunnel.protocol == 'SMB') {
          // If credentials are not saved or not provided, show auth dialog
          if (!tunnel.saveCredentials || tunnel.username == null || tunnel.password == null) {
            final updatedTunnel = await showDialog<Tunnel>(
              context: context,
              barrierDismissible: false,
              builder: (context) => SmbAuthDialog(tunnel: tunnel),
            );
            
            // If dialog was cancelled, return
            if (updatedTunnel == null) return;
            
            // Save the updated tunnel with credentials
            await provider.saveTunnel(updatedTunnel);
            
            // Start the tunnel with the updated credentials
            await provider.startForwarding(updatedTunnel.domain, updatedTunnel.port, context: context);
          } else {
            // Start the tunnel with existing credentials
            await provider.startForwarding(tunnel.domain, tunnel.port, context: context);
          }
        } else {
          // Start non-SMB tunnel normally
          await provider.startForwarding(tunnel.domain, tunnel.port);
        }
      } on WinFspNotInstalledException catch (e) {
        if (!mounted) return;
        
        // Show dialog with installation instructions
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('WinFsp Required'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.toString()),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () async {
                    final url = Uri.parse('https://github.com/winfsp/winfsp/releases/download/v2.0/winfsp-2.0.23075.msi');
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url);
                    }
                  },
                  child: const Text('Download WinFsp Manually'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }
}
