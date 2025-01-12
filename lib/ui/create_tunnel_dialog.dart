import 'package:flutter/material.dart';
import '../services/cloudflared_service.dart';

class CreateTunnelDialog extends StatefulWidget {
  const CreateTunnelDialog({super.key});

  @override
  State<CreateTunnelDialog> createState() => _CreateTunnelDialogState();
}

class _CreateTunnelDialogState extends State<CreateTunnelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _domainController = TextEditingController();
  final _cfService = CloudflaredService();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _createTunnel() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Create the tunnel
      final result = await _cfService.createTunnel(_nameController.text);
      if (!result['success']) {
        setState(() {
          _error = result['error'];
          _isLoading = false;
        });
        return;
      }

      final tunnelId = result['tunnelId'];

      // Route the domain to the tunnel
      final routeSuccess = await _cfService.routeTunnel(tunnelId, _domainController.text);
      if (!routeSuccess) {
        // If routing fails, try to clean up by deleting the tunnel
        await _cfService.deleteTunnel(tunnelId);
        setState(() {
          _error = 'Failed to route domain to tunnel';
          _isLoading = false;
        });
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop({
        'success': true,
        'tunnelId': tunnelId,
        'name': _nameController.text,
        'domain': _domainController.text,
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create New Tunnel'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Tunnel Name',
                  hintText: 'my-awesome-tunnel',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a tunnel name';
                  }
                  if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(value)) {
                    return 'Only letters, numbers, and hyphens allowed';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _domainController,
                decoration: const InputDecoration(
                  labelText: 'Domain',
                  hintText: 'myapp.example.com',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a domain';
                  }
                  if (!RegExp(r'^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$').hasMatch(value)) {
                    return 'Please enter a valid domain';
                  }
                  return null;
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _createTunnel,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
} 