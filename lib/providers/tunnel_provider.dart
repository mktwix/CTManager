// lib/providers/tunnel_provider.dart

import 'package:flutter/foundation.dart';
import '../models/tunnel.dart';
import '../services/database_service.dart';
import '../services/cloudflared_service.dart';
import 'package:logger/logger.dart';

class TunnelProvider extends ChangeNotifier {
  final CloudflaredService _cfService = CloudflaredService();
  final Logger _logger = Logger();
  
  bool _isLoading = true;
  Map<String, String>? _runningTunnel;
  Map<String, String> _forwardingStatus = {};

  bool get isLoading => _isLoading;
  Map<String, String>? get runningTunnel => _runningTunnel;
  Map<String, String> get forwardingStatus => _forwardingStatus;

  TunnelProvider() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _isLoading = true;
      notifyListeners();

      // Check if cloudflared is installed
      final isInstalled = await _cfService.isCloudflaredInstalled();
      if (!isInstalled) {
        _logger.e('Cloudflared is not installed');
        return;
      }

      // Get running tunnel info
      await checkRunningTunnel();
    } catch (e) {
      _logger.e('Error initializing TunnelProvider', e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> checkRunningTunnel() async {
    try {
      _runningTunnel = await _cfService.getRunningTunnelInfo();
      notifyListeners();
    } catch (e) {
      _logger.e('Error checking running tunnel', e);
    }
  }

  Future<bool> startForwarding(String domain, String port) async {
    try {
      if (_runningTunnel == null) {
        _logger.e('No running tunnel found');
        return false;
      }

      final success = await _cfService.startPortForwarding(domain, port);
      if (success) {
        _forwardingStatus[domain] = port;
        notifyListeners();
      }
      return success;
    } catch (e) {
      _logger.e('Error starting forwarding', e);
      return false;
    }
  }

  Future<void> stopForwarding(String domain) async {
    try {
      final port = _forwardingStatus[domain];
      if (port != null) {
        await _cfService.stopPortForwarding(port);
        _forwardingStatus.remove(domain);
        notifyListeners();
      }
    } catch (e) {
      _logger.e('Error stopping forwarding', e);
    }
  }

  @override
  void dispose() {
    // Stop all forwardings
    for (final entry in _forwardingStatus.entries) {
      _cfService.stopPortForwarding(entry.value);
    }
    super.dispose();
  }
}
