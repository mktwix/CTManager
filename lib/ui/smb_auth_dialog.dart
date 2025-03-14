import 'package:flutter/material.dart';
import '../models/tunnel.dart';

class SmbAuthDialog extends StatefulWidget {
  final Tunnel tunnel;

  const SmbAuthDialog({
    super.key,
    required this.tunnel,
  });

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
    _usernameController = TextEditingController(text: widget.tunnel.username ?? '');
    _passwordController = TextEditingController(text: widget.tunnel.password ?? '');
    _saveCredentials = widget.tunnel.saveCredentials;
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
      title: const Text('SMB Authentication'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Enter credentials for ${widget.tunnel.domain}'),
              const SizedBox(height: 16),
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
              const SizedBox(height: 8),
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
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              final updatedTunnel = widget.tunnel.copyWith(
                username: _usernameController.text,
                password: _passwordController.text,
                saveCredentials: _saveCredentials,
              );
              Navigator.of(context).pop(updatedTunnel);
            }
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }
} 