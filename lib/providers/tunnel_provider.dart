// lib/providers/tunnel_provider.dart

import 'package:flutter/foundation.dart';
import '../models/tunnel.dart';
import '../services/database_service.dart';
import '../services/cloudflared_service.dart';
import 'package:logger/logger.dart';

class TunnelProvider extends ChangeNotifier {
  List<Tunnel> _tunnels = [];
  final DatabaseService _dbService = DatabaseService();
  final CloudflaredService _cfService = CloudflaredService();
  final Logger _logger = Logger();
  bool _isLoading = true;
  bool _isInitialized = false;

  List<Tunnel> get tunnels => _tunnels;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;

  TunnelProvider() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _isLoading = true;
      notifyListeners();

      // Initialize database
      await _dbService.init();
      _isInitialized = true;

      // Detect any running tunnel first
      await _cfService.detectRunningTunnel();

      // Load initial data
      await loadTunnels();
    } catch (e) {
      _logger.e('Error initializing TunnelProvider: $e');
      _tunnels = [];
      _isInitialized = true;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadTunnels() async {
    if (!_isInitialized) {
      _logger.w('Trying to load tunnels before initialization');
      return;
    }

    try {
      _isLoading = true;
      notifyListeners();

      _tunnels = await _dbService.getTunnels();
      
      // Only check running status for local tunnel
      for (var tunnel in _tunnels) {
        if (tunnel.isLocal) {
          try {
            tunnel.isRunning = _cfService.isTunnelRunning(tunnel);
          } catch (e) {
            _logger.e('Error checking tunnel status: $e');
            tunnel.isRunning = false;
          }
        }
      }
    } catch (e) {
      _logger.e('Error loading tunnels: $e');
      _tunnels = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> addTunnel(Tunnel tunnel) async {
    try {
      // Ensure only one local tunnel exists
      if (tunnel.isLocal) {
        final existingLocalTunnel = _tunnels.any((t) => t.isLocal);
        if (existingLocalTunnel) {
          _logger.e('A local tunnel already exists');
          return false;
        }
      }

      final id = await _dbService.insertTunnel(tunnel);
      if (id != -1) {
        await loadTunnels();
        return true;
      }
      return false;
    } catch (e) {
      _logger.e('Error adding tunnel: $e');
      return false;
    }
  }

  Future<bool> updateTunnel(Tunnel tunnel) async {
    try {
      final rowsAffected = await _dbService.updateTunnel(tunnel);
      if (rowsAffected > 0) {
        await loadTunnels();
        return true;
      }
      return false;
    } catch (e) {
      _logger.e('Error updating tunnel: $e');
      return false;
    }
  }

  Future<bool> deleteTunnel(int id) async {
    try {
      final rowsAffected = await _dbService.deleteTunnel(id);
      if (rowsAffected > 0) {
        await loadTunnels();
        return true;
      }
      return false;
    } catch (e) {
      _logger.e('Error deleting tunnel: $e');
      return false;
    }
  }

  Future<bool> startTunnel(Tunnel tunnel) async {
    try {
      if (!tunnel.isLocal) {
        _logger.e('Cannot start a remote tunnel');
        return false;
      }
      await _cfService.startTunnel(tunnel);
      tunnel.isRunning = true;
      notifyListeners();
      return true;
    } catch (e) {
      _logger.e('Error starting tunnel: $e');
      return false;
    }
  }

  Future<bool> stopTunnel(Tunnel tunnel) async {
    try {
      if (!tunnel.isLocal) {
        _logger.e('Cannot stop a remote tunnel');
        return false;
      }
      await _cfService.stopTunnel(tunnel);
      tunnel.isRunning = false;
      notifyListeners();
      return true;
    } catch (e) {
      _logger.e('Error stopping tunnel: $e');
      return false;
    }
  }

  void terminateAllTunnels() {
    for (var tunnel in _tunnels) {
      if (tunnel.isLocal && tunnel.isRunning) {
        _cfService.stopTunnel(tunnel);
      }
    }
  }

  bool isTunnelRunning(Tunnel tunnel) {
    if (!tunnel.isLocal) return false;
    return _cfService.isTunnelRunning(tunnel);
  }

  @override
  void dispose() {
    terminateAllTunnels();
    _dbService.close();
    super.dispose();
  }
}
