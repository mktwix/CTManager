// lib/ui/home_page.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tunnel_provider.dart';
import '../models/tunnel.dart';
import 'tunnel_form.dart';
import 'tunnel_list_item.dart';
import '../services/log_service.dart';
import 'package:flutter/services.dart';

const cloudflareOrange = Color(0xFFF48120);
const cloudflareBlue = Color(0xFF404242);

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
                                      Text(
                                        provider.runningTunnel!['name'] ?? 'Unnamed Tunnel',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                        ),
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
                                                            if (!tunnel.isRunning) {
                                                              provider.startForwarding(tunnel.domain, tunnel.port);
                                                            }
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
                                                            if (tunnel.isRunning) {
                                                              provider.stopForwarding(tunnel.domain);
                                                            }
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
