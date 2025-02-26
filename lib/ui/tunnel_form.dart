// lib/ui/tunnel_form.dart

import 'package:flutter/material.dart';
import '../models/tunnel.dart';
import '../providers/tunnel_provider.dart';
import 'package:provider/provider.dart';
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
  }

  @override
  void dispose() {
    _portController.dispose();
    _domainController.dispose();
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
                ],
                onChanged: (value) {
                  setState(() {
                    _protocol = value!;
                    // Update port if it's still at default value
                    if (_portController.text == '4000' || _portController.text == '4001') {
                      _portController.text = value == 'RDP' ? '3389' : '22';
                    }
                  });
                },
                decoration: const InputDecoration(labelText: 'Protocol'),
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
              );
              
              // Save tunnel configuration
              await provider.saveTunnel(tunnel);
              
              // If it was running before, start it again with new configuration
              if (wasRunning) {
                await provider.startForwarding(tunnel.domain, tunnel.port);
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
