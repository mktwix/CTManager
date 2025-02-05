// lib/providers/tunnel_provider.dart

import 'package:flutter/foundation.dart';
import '../models/tunnel.dart';
import '../services/database_service.dart';
import '../services/cloudflared_service.dart';
import 'package:logger/logger.dart';
import 'dart:io';
import '../services/log_service.dart';

class TunnelProvider extends ChangeNotifier {
  final CloudflaredService _cfService = CloudflaredService();
  final Logger _logger = Logger();
  
  bool _isLoading = true;
  Map<String, String>? _runningTunnel;
  Map<String, String> _forwardingStatus = {};
  List<Tunnel> _tunnels = [];
  String? _error;

  bool get isLoading => _isLoading;
  Map<String, String>? get runningTunnel => _runningTunnel;
  Map<String, String> get forwardingStatus => _forwardingStatus;
  List<Tunnel> get tunnels => _tunnels;
  String? get error => _error;

  TunnelProvider() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      // Check if cloudflared is installed
      final isInstalled = await _cfService.isCloudflaredInstalled();
      if (!isInstalled) {
        _error = 'Cloudflared is not installed';
        _logger.e(_error!);
        return;
      }

      // Load tunnels from database first
      await loadTunnels();

      // Get running tunnel processes and update states
      await checkRunningTunnel();
    } catch (e, stack) {
      _error = 'Failed to initialize: ${e.toString()}';
      _logger.e(_error!, e, stack);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> checkRunningTunnel() async {
    try {
      _isLoading = true;
      notifyListeners();
      
      LogService().addLog('Checking running tunnel state...');
      LogService().addLog('Current forwarding status: $_forwardingStatus');
      LogService().addLog('Current tunnels: ${_tunnels.map((t) => '${t.domain}:${t.port} (running: ${t.isRunning})')}');
      
      // Get all currently running cloudflared processes
      final runningProcesses = await _cfService.getRunningCloudflaredProcesses();
      LogService().addLog('Found running processes: $runningProcesses');
      
      // Clear and rebuild forwarding status based on running processes
      _forwardingStatus.clear();
      
      // Update tunnel states based on running processes
      for (var tunnel in _tunnels) {
        final isRunning = runningProcesses.containsKey(tunnel.domain) && 
                         runningProcesses[tunnel.domain].toString() == tunnel.port;
        
        LogService().addLog('Checking tunnel ${tunnel.domain}:${tunnel.port} - Current state: ${tunnel.isRunning}, Detected state: $isRunning');
        
        // If the tunnel is running, make sure it's in the forwarding status
        if (isRunning) {
          LogService().addLog('Adding to forwarding status: ${tunnel.domain} -> ${tunnel.port}');
          _forwardingStatus[tunnel.domain] = tunnel.port;
        }
        
        if (tunnel.isRunning != isRunning) {
          LogService().addLog('State mismatch detected for ${tunnel.domain} - Updating state');
          final updatedTunnel = tunnel.copyWith(isRunning: isRunning);
          await saveTunnel(updatedTunnel);
        }
      }
      
      LogService().addLog('Updated forwarding status map: $_forwardingStatus');
      
      // Get running tunnel info from cloudflared service
      _runningTunnel = await _cfService.getRunningTunnelInfo();
      LogService().addLog('Running tunnel info: $_runningTunnel');
      
    } catch (e, stack) {
      _logger.e('Error checking running tunnel', e, stack);
      LogService().addLog('Error checking running tunnel: $e');
      LogService().addLog('Stack trace: $stack');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> startForwarding(String domain, String port) async {
    try {
      LogService().addLog('Attempting to start forwarding for $domain on port $port');
      
      final success = await _cfService.startPortForwarding(domain, port);
      if (success) {
        LogService().addLog('Successfully started forwarding for $domain on port $port');
        _forwardingStatus[domain] = port;
        
        // Update running status of the tunnel
        final tunnelIndex = _tunnels.indexWhere((t) => t.domain == domain);
        if (tunnelIndex != -1) {
          final tunnel = _tunnels[tunnelIndex];
          final updatedTunnel = tunnel.copyWith(isRunning: true);
          _tunnels[tunnelIndex] = updatedTunnel;
          notifyListeners();
        }
      } else {
        LogService().addLog('Failed to start forwarding for $domain on port $port');
        _logger.e('Failed to start forwarding for $domain:$port');
      }
    } catch (e, stack) {
      LogService().addLog('Error starting forwarding for $domain on port $port: $e');
      _logger.e('Failed to start forwarding', e, stack);
    }
  }

  Future<void> stopForwarding(String domain) async {
    try {
      LogService().addLog('Attempting to stop forwarding for $domain');
      LogService().addLog('Current forwarding status: $_forwardingStatus');
      
      final port = _forwardingStatus[domain];
      if (port != null) {
        LogService().addLog('Found port $port for domain $domain');
        
        // Update running status of the tunnel before stopping
        final tunnelIndex = _tunnels.indexWhere((t) => t.domain == domain);
        if (tunnelIndex != -1) {
          final tunnel = _tunnels[tunnelIndex];
          LogService().addLog('Found tunnel in list: ${tunnel.domain}:${tunnel.port} (running: ${tunnel.isRunning})');
        }
        
        await _cfService.stopPortForwarding(port);
        _forwardingStatus.remove(domain);
        LogService().addLog('Successfully stopped forwarding for $domain');
        LogService().addLog('Updated forwarding status: $_forwardingStatus');
        
        // Update running status of the tunnel
        if (tunnelIndex != -1) {
          final tunnel = _tunnels[tunnelIndex];
          final updatedTunnel = tunnel.copyWith(isRunning: false);
          _tunnels[tunnelIndex] = updatedTunnel;
          LogService().addLog('Updated tunnel state: ${updatedTunnel.domain}:${updatedTunnel.port} (running: ${updatedTunnel.isRunning})');
          notifyListeners();
        }
      } else {
        LogService().addLog('No port found for domain $domain in forwarding status');
      }
    } catch (e, stack) {
      LogService().addLog('Error stopping forwarding for $domain: $e');
      LogService().addLog('Stack trace: $stack');
      _logger.e('Failed to stop forwarding', e, stack);
    }
  }

  Future<void> loadTunnels() async {
    try {
      final db = await DatabaseService.instance.database;
      final List<Map<String, dynamic>> maps = await db.query('tunnels');
      _tunnels = List.generate(maps.length, (i) {
        return Tunnel.fromJson(maps[i]);
      });
      notifyListeners();
    } catch (e, stack) {
      _error = 'Failed to load tunnels: ${e.toString()}';
      _logger.e(_error!, e, stack);
      rethrow;
    }
  }

  Future<void> saveTunnel(Tunnel tunnel) async {
    try {
      final db = await DatabaseService.instance.database;
      final index = _tunnels.indexWhere((t) => t.id == tunnel.id);
      
      if (index >= 0) {
        await db.update(
          'tunnels',
          tunnel.toMap(),
          where: 'id = ?',
          whereArgs: [tunnel.id],
        );
        _tunnels[index] = tunnel;
      } else {
        final id = await db.insert(
          'tunnels',
          tunnel.copyWith(
            id: DateTime.now().millisecondsSinceEpoch,
          ).toMap(),
        );
        _tunnels.add(tunnel.copyWith(id: id));
      }
      
      notifyListeners();
    } catch (e, stack) {
      _error = 'Failed to save tunnel: ${e.toString()}';
      _logger.e(_error!, e, stack);
      rethrow;
    }
  }

  Future<void> deleteTunnel(int id) async {
    try {
      // Find the tunnel first
      final tunnel = _tunnels.firstWhere((t) => t.id == id);
      
      // If tunnel is running, stop it first
      if (tunnel.isRunning) {
        await stopForwarding(tunnel.domain);
      }
      
      final db = await DatabaseService.instance.database;
      await db.delete(
        'tunnels',
        where: 'id = ?',
        whereArgs: [id],
      );
      _tunnels.removeWhere((t) => t.id == id);
      notifyListeners();
    } catch (e, stack) {
      _error = 'Failed to delete tunnel: ${e.toString()}';
      _logger.e(_error!, e, stack);
      rethrow;
    }
  }

  Future<void> launchConnection(Tunnel tunnel) async {
    try {
      if (tunnel.protocol == 'RDP') {
        await Process.run('mstsc', ['/v:localhost:${tunnel.port}'], runInShell: true);
      } else if (tunnel.protocol == 'SSH') {
        // Open SSH in a new PowerShell window with proper connection to localhost
        await Process.run(
          'powershell', 
          [
            'Start-Process',
            'powershell',
            '-ArgumentList',
            '"-NoExit -Command ssh root@localhost -p ${tunnel.port}"'
          ],
          runInShell: true
        );
      }
    } catch (e) {
      _logger.e('Error launching connection: $e');
    }
  }

  Future<void> startTunnel(Tunnel tunnel) async {
    try {
      _error = null;
      final success = await _cfService.startPortForwarding(tunnel.domain, tunnel.port);
      if (success) {
        final updatedTunnel = tunnel.copyWith(isRunning: true);
        await saveTunnel(updatedTunnel);
      } else {
        _error = 'Failed to start tunnel';
        notifyListeners();
      }
    } catch (e, stack) {
      _error = 'Error starting tunnel: ${e.toString()}';
      _logger.e(_error!, e, stack);
      rethrow;
    }
  }

  Future<void> stopTunnel(Tunnel tunnel) async {
    try {
      _error = null;
      await _cfService.stopPortForwarding(tunnel.port);
      final updatedTunnel = tunnel.copyWith(isRunning: false);
      await saveTunnel(updatedTunnel);
    } catch (e, stack) {
      _error = 'Error stopping tunnel: ${e.toString()}';
      _logger.e(_error!, e, stack);
      rethrow;
    }
  }

  @override
  void dispose() {
    _cleanupResources();
    super.dispose();
  }

  Future<void> _cleanupResources() async {
    try {
      // Stop all forwardings
      for (final entry in _forwardingStatus.entries) {
        await _cfService.stopPortForwarding(entry.value);
      }
      
      // Close database connection
      await DatabaseService.instance.close();
    } catch (e, stack) {
      _logger.e('Error during cleanup', e, stack);
    }
  }
}
