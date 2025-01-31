// lib/providers/tunnel_provider.dart

import 'package:flutter/foundation.dart';
import '../models/tunnel.dart';
import '../services/database_service.dart';
import '../services/cloudflared_service.dart';
import 'package:logger/logger.dart';
import 'package:process/process.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class TunnelProvider extends ChangeNotifier {
  final CloudflaredService _cfService = CloudflaredService();
  final Logger _logger = Logger();
  
  bool _isLoading = true;
  Map<String, String>? _runningTunnel;
  Map<String, String> _forwardingStatus = {};
  List<Tunnel> _tunnels = [];

  bool get isLoading => _isLoading;
  Map<String, String>? get runningTunnel => _runningTunnel;
  Map<String, String> get forwardingStatus => _forwardingStatus;
  List<Tunnel> get tunnels => _tunnels;

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
      await loadTunnels();
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

  Future<void> loadTunnels() async {
    final prefs = await SharedPreferences.getInstance();
    final tunnelsJson = prefs.getStringList('tunnels') ?? [];
    _tunnels = tunnelsJson
        .map((json) => Tunnel.fromJson(jsonDecode(json)))
        .toList();
    notifyListeners();
  }

  Future<void> saveTunnel(Tunnel tunnel) async {
    final index = _tunnels.indexWhere((t) => t.id == tunnel.id);
    if (index >= 0) {
      _tunnels[index] = tunnel;
    } else {
      _tunnels.add(tunnel.copyWith(
        id: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    await _saveToPrefs();
    notifyListeners();
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final tunnelsJson = _tunnels.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList('tunnels', tunnelsJson);
  }

  Future<void> deleteTunnel(int id) async {
    final db = await DatabaseService.instance.database;
    await db.delete(
      'tunnels',
      where: 'id = ?',
      whereArgs: [id],
    );
    await loadTunnels();
  }

  Future<void> launchConnection(Tunnel tunnel) async {
    try {
      await Process.run('cmd', ['/c', tunnel.launchCommand], runInShell: true);
    } catch (e) {
      _logger.e('Error launching connection: $e');
    }
  }

  Future<void> startTunnel(Tunnel tunnel) async {
    try {
      await _cfService.startTunnel(tunnel);
      final updatedTunnel = Tunnel(
        id: tunnel.id,
        domain: tunnel.domain,
        port: tunnel.port,
        protocol: tunnel.protocol,
        isRunning: true,
        isLocal: tunnel.isLocal,
      );
      await saveTunnel(updatedTunnel);
    } catch (e) {
      _logger.e('Error starting tunnel: $e');
    }
  }

  Future<void> stopTunnel(Tunnel tunnel) async {
    try {
      await _cfService.stopTunnel(tunnel);
      final updatedTunnel = Tunnel(
        id: tunnel.id,
        domain: tunnel.domain,
        port: tunnel.port,
        protocol: tunnel.protocol,
        isRunning: false,
        isLocal: tunnel.isLocal,
      );
      await saveTunnel(updatedTunnel);
    } catch (e) {
      _logger.e('Error stopping tunnel: $e');
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
