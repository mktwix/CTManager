// lib/ui/tunnel_form.dart

import 'package:flutter/material.dart';
import '../models/tunnel.dart';
import '../providers/tunnel_provider.dart';
import 'package:provider/provider.dart';
import '../services/smb_service.dart';
// Removed unused import
// import 'package:logger/logger.dart';

class TunnelForm extends StatefulWidget {
  final String? initialProtocol;
  final String? initialPort;
  final String? initialDomain;
  final Tunnel? tunnel;
  final bool isLocal;

  const TunnelForm({
    super.key, 
    this.initialProtocol,
    this.initialPort,
    this.initialDomain,
    this.tunnel,
    this.isLocal = false,
  });

  @override
  State<TunnelForm> createState() => _TunnelFormState();
}

class _TunnelFormState extends State<TunnelForm> {
  final _formKey = GlobalKey<FormState>();
  late String _protocol;
  late TextEditingController _portController;
  late TextEditingController _domainController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  bool _saveCredentials = false;
  bool _showAuthFields = false;
  bool _autoSelectDrive = true;
  String? _preferredDriveLetter;
  List<String> _availableDriveLetters = [];
  bool _isLoadingDriveLetters = false;

  @override
  void initState() {
    super.initState();
    _protocol = widget.tunnel?.protocol ?? widget.initialProtocol ?? 'RDP';
    _portController = TextEditingController(
      text: widget.tunnel?.port ?? widget.initialPort ?? '4000'
    );
    _domainController = TextEditingController(
      text: widget.tunnel?.domain ?? widget.initialDomain ?? ''
    );
    _usernameController = TextEditingController(
      text: widget.tunnel?.username ?? ''
    );
    _passwordController = TextEditingController(
      text: widget.tunnel?.password ?? ''
    );
    _saveCredentials = widget.tunnel?.saveCredentials ?? false;
    _showAuthFields = _protocol == 'SMB';
    _autoSelectDrive = widget.tunnel?.autoSelectDrive ?? true;
    _preferredDriveLetter = widget.tunnel?.preferredDriveLetter;
    
    if (_showAuthFields) {
      _loadAvailableDriveLetters();
    }
  }

  Future<void> _loadAvailableDriveLetters() async {
    setState(() {
      _isLoadingDriveLetters = true;
    });

    try {
      _availableDriveLetters = await SmbService().getAvailableDriveLetters();
      
      // If we have a preferred drive letter that's not in the available list,
      // add it with a note that it's currently in use
      if (_preferredDriveLetter != null && 
          !_availableDriveLetters.contains(_preferredDriveLetter)) {
        _availableDriveLetters.add(_preferredDriveLetter!);
      }
      
      // If no preferred drive letter is set but we have available letters, select the first one
      if (_preferredDriveLetter == null && _availableDriveLetters.isNotEmpty && !_autoSelectDrive) {
        _preferredDriveLetter = _availableDriveLetters.first;
      }
    } catch (e) {
      // Handle error
    } finally {
      setState(() {
        _isLoadingDriveLetters = false;
      });
    }
  }

  @override
  void dispose() {
    _portController.dispose();
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.tunnel == null ? 'Add Tunnel' : 'Edit Tunnel'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _domainController,
                decoration: const InputDecoration(labelText: 'Domain'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a domain';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  helperText: 'Ports 4000+ recommended for local services',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a port';
                  }
                  final port = int.tryParse(value);
                  if (port == null || port <= 0 || port > 65535) {
                    return 'Please enter a valid port number';
                  }
                  return null;
                },
              ),
              DropdownButtonFormField<String>(
                value: _protocol,
                items: const [
                  DropdownMenuItem(value: 'RDP', child: Text('Remote Desktop')),
                  DropdownMenuItem(value: 'SSH', child: Text('SSH')),
                  DropdownMenuItem(value: 'SMB', child: Text('SMB File Share')),
                ],
                onChanged: (value) {
                  setState(() {
                    _protocol = value!;
                    // Update port if it's still at default value
                    if (_portController.text == '4000' || _portController.text == '4001') {
                      if (value == 'RDP') {
                        _portController.text = '3389';
                      } else if (value == 'SSH') {
                        _portController.text = '22';
                      } else if (value == 'SMB') {
                        _portController.text = '445';
                      }
                    }
                    // Show authentication fields for SMB
                    _showAuthFields = value == 'SMB';
                    
                    if (_showAuthFields && _availableDriveLetters.isEmpty) {
                      _loadAvailableDriveLetters();
                    }
                  });
                },
                decoration: const InputDecoration(labelText: 'Protocol'),
              ),
              if (_showAuthFields) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                  validator: (value) {
                    if (_protocol == 'SMB' && (value == null || value.isEmpty)) {
                      return 'Please enter a username for SMB';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                  validator: (value) {
                    if (_protocol == 'SMB' && (value == null || value.isEmpty)) {
                      return 'Please enter a password for SMB';
                    }
                    return null;
                  },
                ),
                CheckboxListTile(
                  title: const Text('Save Credentials'),
                  value: _saveCredentials,
                  onChanged: (value) {
                    setState(() {
                      _saveCredentials = value ?? false;
                    });
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Drive Letter Options',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  title: const Text('Auto-select drive letter'),
                  subtitle: const Text('Let the app choose the first available drive letter'),
                  value: _autoSelectDrive,
                  onChanged: (value) {
                    setState(() {
                      _autoSelectDrive = value ?? true;
                    });
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                if (!_autoSelectDrive) ...[
                  const SizedBox(height: 8),
                  _isLoadingDriveLetters
                      ? const Center(child: CircularProgressIndicator())
                      : _availableDriveLetters.isEmpty
                          ? const Text(
                              'No drive letters available',
                              style: TextStyle(color: Colors.red),
                            )
                          : DropdownButtonFormField<String>(
                              decoration: const InputDecoration(
                                labelText: 'Preferred Drive Letter',
                              ),
                              value: _preferredDriveLetter ?? _availableDriveLetters.first,
                              items: _availableDriveLetters.map((letter) {
                                return DropdownMenuItem<String>(
                                  value: letter,
                                  child: Text('$letter:'),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() {
                                  _preferredDriveLetter = value;
                                });
                              },
                            ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            if (_formKey.currentState!.validate()) {
              _formKey.currentState!.save();
              
              final provider = context.read<TunnelProvider>();
              final wasRunning = widget.tunnel?.isRunning ?? false;
              
              // If tunnel is running, stop it first
              if (wasRunning) {
                await provider.stopForwarding(widget.tunnel!.domain);
              }
              
              final tunnel = Tunnel(
                id: widget.tunnel?.id,
                domain: _domainController.text,
                port: _portController.text,
                protocol: _protocol,
                isLocal: widget.isLocal,
                username: _protocol == 'SMB' ? _usernameController.text : null,
                password: _protocol == 'SMB' ? _passwordController.text : null,
                saveCredentials: _protocol == 'SMB' ? _saveCredentials : false,
                preferredDriveLetter: _protocol == 'SMB' && !_autoSelectDrive ? _preferredDriveLetter : null,
                autoSelectDrive: _protocol == 'SMB' ? _autoSelectDrive : true,
              );
              
              // Save tunnel configuration
              await provider.saveTunnel(tunnel);
              
              // If it was running before, start it again with new configuration
              if (wasRunning) {
                if (tunnel.protocol == 'SMB') {
                  await provider.startForwarding(tunnel.domain, tunnel.port, context: context);
                } else {
                  await provider.startForwarding(tunnel.domain, tunnel.port);
                }
              }
                
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
