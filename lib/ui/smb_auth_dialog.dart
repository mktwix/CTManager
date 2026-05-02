import 'package:flutter/material.dart';
import '../models/tunnel.dart';
import '../services/secure_storage_service.dart';

class SmbAuthDialog extends StatefulWidget {
  final Tunnel tunnel;

  const SmbAuthDialog({super.key, required this.tunnel});

  @override
  State<SmbAuthDialog> createState() => _SmbAuthDialogState();
}

class _SmbAuthDialogState extends State<SmbAuthDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  bool _saveCredentials = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _saveCredentials = widget.tunnel.saveCredentials;

    // Load saved credentials if they exist
    if (_saveCredentials) {
      _loadCredentials();
    }
  }

  Future<void> _loadCredentials() async {
    final username = await SecureStorageService.getUsername(widget.tunnel.domain);
    final password = await SecureStorageService.getPassword(widget.tunnel.domain);
    setState(() {
      _usernameController.text = username ?? '';
      _passwordController.text = password ?? '';
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('SMB Authentication for ${widget.tunnel.domain}'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a username';
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
                if (value == null || value.isEmpty) {
                  return 'Please enter a password';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: const Text('Save Credentials'),
              value: _saveCredentials,
              onChanged: (value) {
                setState(() {
                  _saveCredentials = value ?? false;
                });
              },
            ),
          ],
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
              final username = _usernameController.text;
              final password = _passwordController.text;

              if (_saveCredentials) {
                await SecureStorageService.saveCredentials(widget.tunnel.domain, username, password);
              } else {
                // If the user unchecks the box, delete any previously saved credentials
                await SecureStorageService.deleteCredentials(widget.tunnel.domain);
              }

              // Return the credentials for the current session
              if (!mounted) return;
              // ignore: use_build_context_synchronously
              Navigator.of(context).pop({
                'username': username,
                'password': password,
                'saveCredentials': _saveCredentials,
              });
            }
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }
} 