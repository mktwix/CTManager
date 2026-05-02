// lib/ui/home_page.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tunnel_provider.dart';
import '../models/tunnel.dart';
import 'tunnel_list_item.dart';
import '../services/log_service.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../services/smb_exceptions.dart';
import '../services/secure_storage_service.dart';
import '../main.dart';  // Import main.dart to access the color definitions

// Using colors defined in main.dart
// const cloudflareOrange = Color(0xFFF48120);
// const cloudflareBlue = Color(0xFF404242);

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LogCategory? _selectedCategory;
  bool _isInitialLoad = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isInitialLoad) {
      final provider = Provider.of<TunnelProvider>(context, listen: false);
      if (!provider.isLoading) {
        setState(() {
          _isInitialLoad = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TunnelProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          backgroundColor: Colors.grey[100],
          appBar: AppBar(
            backgroundColor: cloudflareOrange,
            title: const Text('Cloudflare Tunnel Access Manager'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh UI and check tunnel status',
                onPressed: () => provider.checkRunningTunnel(),
              ),
            ],
          ),
          body: _isInitialLoad && provider.isLoading
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
                            'No tunnel access configured',
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
                                    color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
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

                        // Main content area - responsive layout
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final isNarrow = constraints.maxWidth < 800;
                              if (isNarrow) {
                                return SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      SizedBox(
                                        height: 380,
                                        child: _buildPortForwardingCard(context, provider),
                                      ),
                                      SizedBox(
                                        height: 380,
                                        child: _buildLogsCard(context),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: 1,
                                    child: _buildPortForwardingCard(context, provider),
                                  ),
                                  Expanded(
                                    flex: 1,
                                    child: _buildLogsCard(context),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _buildPortForwardingCard(BuildContext context, TunnelProvider provider) {
    return Card(
      margin: const EdgeInsets.only(left: 16, right: 8, bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Domain Access',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.upload_outlined, color: Theme.of(context).primaryColor),
                      tooltip: 'Export',
                      onPressed: () => _handleExport(context),
                    ),
                    IconButton(
                      icon: Icon(Icons.download_outlined, color: Theme.of(context).primaryColor),
                      tooltip: 'Import',
                      onPressed: () => _handleImport(context),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.play_arrow_rounded, color: Colors.grey[700]),
                            tooltip: 'Start All',
                            onPressed: () {
                              for (var tunnel in provider.tunnels) {
                                if (!tunnel.isRunning) _toggleTunnel(tunnel);
                              }
                            },
                          ),
                          IconButton(
                            icon: Icon(Icons.stop_rounded, color: Colors.grey[700]),
                            tooltip: 'Stop All',
                            onPressed: () {
                              for (var tunnel in provider.tunnels) {
                                if (tunnel.isRunning) _toggleTunnel(tunnel);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add_circle_outline, color: Theme.of(context).primaryColor),
                      tooltip: 'Add Access',
                      onPressed: () => _showAddForwardDialog(context),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: provider.tunnels.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_road_outlined, size: 48, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            'No saved domain forwards',
                            style: TextStyle(color: Colors.grey[600], fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap + to add one',
                            style: TextStyle(color: Colors.grey[400], fontSize: 13),
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
    );
  }

  Widget _buildLogsCard(BuildContext context) {
    return Card(
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
                    Icon(Icons.article_outlined, size: 20, color: Colors.grey[700]),
                    const SizedBox(width: 8),
                    const Text(
                      'Logs',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 16),
                    DropdownButton<LogCategory?>(
                      value: _selectedCategory,
                      underline: const SizedBox(),
                      hint: Text('All', style: TextStyle(color: Colors.grey[700], fontSize: 13)),
                      isDense: true,
                      items: [
                        DropdownMenuItem<LogCategory?>(
                          value: null,
                          child: Text('All', style: TextStyle(color: Colors.grey[700], fontSize: 13)),
                        ),
                        ...LogCategory.values.map((category) {
                          return DropdownMenuItem<LogCategory?>(
                            value: category,
                            child: Text(
                              category.name.toUpperCase(),
                              style: TextStyle(color: Colors.grey[700], fontSize: 13),
                            ),
                          );
                        }),
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
                    TextButton.icon(
                      icon: Icon(Icons.copy_outlined, size: 18, color: Colors.grey[700]),
                      onPressed: () {
                        final text = LogService()
                            .getLogsByCategory(_selectedCategory)
                            .map((l) => l.toString())
                            .join('\n');
                        if (text.isNotEmpty) {
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Logs copied to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      label: Text('Copy', style: TextStyle(color: Colors.grey[800], fontSize: 13)),
                    ),
                    TextButton.icon(
                      icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.grey[700]),
                      onPressed: () {
                        LogService().clearLogs();
                        setState(() {});
                      },
                      label: Text('Clear', style: TextStyle(color: Colors.grey[800], fontSize: 13)),
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
                final logsList = LogService().getLogsByCategory(_selectedCategory).toList();
                final logs = logsList.reversed.toList();
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      return SelectableText(
                        log.toString(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.grey[800],
                          height: 1.5,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
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
        title: const Text('Add Domain Access'),
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
              const SizedBox(height: 16),
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
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Protocol',
                ),
                initialValue: protocol,
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
                      content: Text('Domain access added successfully'),
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
    final formKey = GlobalKey<FormState>();
    final domainController = TextEditingController(text: tunnel.domain);
    final portController = TextEditingController(text: tunnel.port);
    final remotePathController = TextEditingController(text: tunnel.remotePath ?? '');
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    // These must live in the outer closure so they survive StatefulBuilder rebuilds
    String protocol = tunnel.protocol;
    bool saveCredentials = tunnel.saveCredentials;

    // Load saved credentials asynchronously if needed
    if (tunnel.saveCredentials && tunnel.protocol == 'SMB') {
      SecureStorageService.getUsername(tunnel.domain).then((u) {
        if (u != null) usernameController.text = u;
      });
      SecureStorageService.getPassword(tunnel.domain).then((p) {
        if (p != null) passwordController.text = p;
      });
    }

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {

          return AlertDialog(
            title: const Text('Edit Domain Access'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: domainController,
                        decoration: const InputDecoration(labelText: 'Domain'),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter a domain';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: portController,
                        decoration: const InputDecoration(labelText: 'Port'),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter a port';
                          }
                          if (int.tryParse(value) == null) {
                            return 'Please enter a valid number';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: protocol,
                        decoration: const InputDecoration(labelText: 'Protocol'),
                        items: ['TCP', 'UDP', 'RDP', 'SSH', 'SMB']
                            .map((label) => DropdownMenuItem(
                                  value: label,
                                  child: Text(label),
                                ))
                            .toList(),
                        onChanged: (value) {
                          // setDialogState triggers a rebuild so SMB fields appear/disappear
                          setDialogState(() {
                            protocol = value!;
                          });
                        },
                      ),
                      if (protocol == 'SMB') ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: remotePathController,
                          decoration: const InputDecoration(
                              labelText: 'Remote Path (optional)',
                              hintText: 'e.g., /share or /c\$/Users/user'),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: usernameController,
                          decoration: const InputDecoration(labelText: 'Username'),
                          validator: (value) {
                            if (protocol == 'SMB' && (value == null || value.isEmpty)) {
                              return 'Please enter a username for SMB';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: passwordController,
                          decoration: const InputDecoration(labelText: 'Password'),
                          obscureText: true,
                          validator: (value) {
                            if (protocol == 'SMB' && (value == null || value.isEmpty)) {
                              return 'Please enter a password for SMB';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        CheckboxListTile(
                          title: const Text('Save Credentials Securely'),
                          value: saveCredentials,
                          onChanged: (value) {
                            setDialogState(() {
                              saveCredentials = value ?? false;
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  domainController.dispose();
                  portController.dispose();
                  remotePathController.dispose();
                  usernameController.dispose();
                  passwordController.dispose();
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: cloudflareOrange,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  if (formKey.currentState!.validate()) {
                    final newTunnel = Tunnel(
                      id: tunnel.id,
                      domain: domainController.text,
                      port: portController.text,
                      protocol: protocol,
                      isLocal: tunnel.isLocal,
                      isRunning: tunnel.isRunning,
                      remotePath: protocol == 'SMB' ? remotePathController.text : null,
                      saveCredentials: protocol == 'SMB' ? saveCredentials : false,
                    );

                    if (protocol == 'SMB') {
                      if (saveCredentials) {
                        await SecureStorageService.saveCredentials(
                          newTunnel.domain,
                          usernameController.text,
                          passwordController.text,
                        );
                      } else {
                        await SecureStorageService.deleteCredentials(newTunnel.domain);
                      }
                    }

                    // ignore: use_build_context_synchronously
                    final provider = Provider.of<TunnelProvider>(dialogContext, listen: false);
                    final wasRunning = tunnel.isRunning;
                    if (wasRunning) {
                      await provider.stopForwarding(tunnel.domain);
                    }
                    await provider.saveTunnel(newTunnel);
                    if (wasRunning && dialogContext.mounted) {
                      await provider.startForwarding(
                          newTunnel.domain, newTunnel.port,
                          context: dialogContext);
                    }

                    domainController.dispose();
                    portController.dispose();
                    remotePathController.dispose();
                    usernameController.dispose();
                    passwordController.dispose();

                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text('Domain access updated successfully'),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, Tunnel tunnel) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Domain Access'),
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
        dialogTitle: 'Save Domain Forwards Configuration',
        fileName: 'domain_forwards_config.json',
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
            const SnackBar(content: Text('Domain forwards exported successfully')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export domain forwards: $e')),
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

        // Capture provider before using context after async gap
        if (!context.mounted) return;
        // Import the tunnels
        await context.read<TunnelProvider>().importTunnels(jsonStr);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Domain forwards imported successfully')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import domain forwards: $e')),
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
        // For SMB tunnels, we let the provider handle the auth dialog flow.
        await provider.startForwarding(tunnel.domain, tunnel.port, context: context);
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