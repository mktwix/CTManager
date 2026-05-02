// lib/ui/tunnel_form.dart

import 'package:flutter/material.dart';
import '../models/tunnel.dart';
import '../services/secure_storage_service.dart';

class TunnelForm extends StatefulWidget {
  final Tunnel? tunnel;

  const TunnelForm({super.key, this.tunnel});

  @override
  State<TunnelForm> createState() => _TunnelFormState();
}

class _TunnelFormState extends State<TunnelForm> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _domainController;
  late TextEditingController _portController;
  late TextEditingController _remotePathController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  String _protocol = 'TCP';
  bool _saveCredentials = false;

  @override
  void initState() {
    super.initState();
    _domainController = TextEditingController(text: widget.tunnel?.domain ?? '');
    _portController = TextEditingController(text: widget.tunnel?.port ?? '');
    _remotePathController = TextEditingController(text: widget.tunnel?.remotePath ?? '');
    _protocol = widget.tunnel?.protocol ?? 'TCP';
    _saveCredentials = widget.tunnel?.saveCredentials ?? false;

    _usernameController = TextEditingController();
    _passwordController = TextEditingController();

    if (widget.tunnel != null && _saveCredentials) {
      _loadCredentials();
    }
  }

  Future<void> _loadCredentials() async {
    final username = await SecureStorageService.getUsername(widget.tunnel!.domain);
    final password = await SecureStorageService.getPassword(widget.tunnel!.domain);
    setState(() {
      _usernameController.text = username ?? '';
      _passwordController.text = password ?? '';
    });
  }

  @override
  void dispose() {
    _domainController.dispose();
    _portController.dispose();
    _remotePathController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 16),
                TextFormField(
                  controller: _portController,
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
                  initialValue: _protocol,
                  decoration: const InputDecoration(labelText: 'Protocol'),
                  items: ['TCP', 'UDP', 'RDP', 'SSH', 'SMB']
                      .map((label) => DropdownMenuItem(
                            value: label,
                            child: Text(label),
                          ))
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _protocol = value!;
                    });
                  },
                ),
                if (_protocol == 'SMB') ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _remotePathController,
                    decoration: const InputDecoration(
                        labelText: 'Remote Path (optional)',
                        hintText: 'e.g., /share or /c\$/Users/user'),
                  ),
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
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    title: const Text('Save Credentials Securely'),
                    value: _saveCredentials,
                    onChanged: (value) {
                      setState(() {
                        _saveCredentials = value ?? false;
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
    );
  }
}