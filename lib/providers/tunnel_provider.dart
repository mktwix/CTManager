// lib/providers/tunnel_provider.dart
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import '../models/tunnel.dart';
import '../services/cloudflared_service.dart';
import '../services/database_service.dart';
import '../services/log_service.dart';
import '../services/smb_service.dart';
import '../ui/drive_letter_dialog.dart';

class TunnelProvider extends ChangeNotifier {
  final CloudflaredService _cfService = CloudflaredService();
  final SmbService _smbService = SmbService();
  final Logger _logger = Logger();
  
  bool _isLoading = true;
  Map<String, String>? _runningTunnel;
  final Map<String, String> _forwardingStatus = {};
  List<Tunnel> _tunnels = [];
  String? _error;
  final Set<String> _processingTunnels = {};

  bool get isLoading => _isLoading;
  Map<String, String>? get runningTunnel => _runningTunnel;
  Map<String, String> get forwardingStatus => _forwardingStatus;
  List<Tunnel> get tunnels => _tunnels;
  String? get error => _error;
  UnmodifiableSetView<String> get processingTunnels => UnmodifiableSetView(_processingTunnels);

  TunnelProvider() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      // Load tunnels from database first
      await loadTunnels();

      // Get running tunnel processes and update states
      await checkRunningTunnel();
    } catch (e) {
      _error = 'Failed to initialize: ${e.toString()}';
      _logger.e('Failed to initialize: ${e.toString()}');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> checkRunningTunnel() async {
    try {
      // _isLoading = true;
      // notifyListeners();
      
      LogService().info('Checking running tunnel state...');
      LogService().info('Current forwarding status: $_forwardingStatus');
      LogService().info('Current tunnels: ${_tunnels.map((t) => '${t.domain}:${t.port} (running: ${t.isRunning})')}');
      
      // Get all currently running cloudflared processes
      final runningProcesses = await _cfService.getRunningCloudflaredProcesses();
      LogService().info('Found running processes: $runningProcesses');
      
      // Update tunnel states based on running processes
      for (var tunnel in _tunnels) {
        final isRunning = runningProcesses.containsKey(tunnel.domain) && 
                         runningProcesses[tunnel.domain].toString() == tunnel.port;
        
        LogService().info('Checking tunnel ${tunnel.domain}:${tunnel.port} - Current state: ${tunnel.isRunning}, Detected state: $isRunning');
        
        // If the tunnel is running, update the forwarding status
        if (isRunning && !_forwardingStatus.containsKey(tunnel.domain)) {
          LogService().info('Adding to forwarding status: ${tunnel.domain} -> ${tunnel.port}');
          _forwardingStatus[tunnel.domain] = tunnel.port;
        }
        
        if (tunnel.isRunning != isRunning) {
          LogService().system('State mismatch detected for ${tunnel.domain} - Updating state');
          final updatedTunnel = tunnel.copyWith(isRunning: isRunning);
          await saveTunnel(updatedTunnel);
        }
      }
      
      LogService().info('Updated forwarding status map: $_forwardingStatus');
      
      // Get running tunnel info from cloudflared service
      _runningTunnel = await _cfService.getRunningTunnelInfo();
      LogService().info('Running tunnel info: $_runningTunnel');
      
    } catch (e, stack) {
      _logger.e('Error checking running tunnel: ${e.toString()}');
      LogService().error('Error checking running tunnel: $e');
      LogService().error('Stack trace: $stack');
    } finally {
      // _isLoading = false;
      // notifyListeners();
    }
  }

  Future<bool> startForwarding(String domain, String port, {BuildContext? context}) async {
    _processingTunnels.add(domain);
    notifyListeners();
    try {
      LogService().info('Starting port forwarding for $domain:$port');
      
      // Find the tunnel in the list
      final tunnelIndex = _tunnels.indexWhere((t) => t.domain == domain);
      if (tunnelIndex == -1) {
        LogService().error('Tunnel not found for $domain');
        return false;
      }
      
      final tunnel = _tunnels[tunnelIndex];
      
      // Start the cloudflared tunnel
      final success = await _cfService.startTunnel(tunnel);
      if (!success) {
        LogService().error('Failed to start cloudflared tunnel for $domain:$port');
        return false;
      }
      
      // Update the forwarding status immediately 
      _forwardingStatus[domain] = port;
      
      // Update the tunnel status
      final updatedTunnel = tunnel.copyWith(isRunning: true);
      await saveTunnel(updatedTunnel);
      
      // If this is an SMB tunnel, mount it as a network drive
      if (tunnel.protocol == 'SMB') {
        try {
          String? selectedDriveLetter;
          
          // If the tunnel has auto-select disabled and a preferred drive letter is set,
          // use that drive letter
          if (!tunnel.autoSelectDrive && tunnel.preferredDriveLetter != null) {
            // Check if the preferred drive letter is available
            final availableDriveLetters = await _smbService.getAvailableDriveLetters();
            if (availableDriveLetters.contains(tunnel.preferredDriveLetter)) {
              selectedDriveLetter = tunnel.preferredDriveLetter;
              LogService().info('Using preferred drive letter: $selectedDriveLetter');
            } else {
              // Preferred drive letter is not available, show a warning and fall back to auto-select
              LogService().warning('Preferred drive letter ${tunnel.preferredDriveLetter} is not available, falling back to auto-select');
              if (context != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Preferred drive letter ${tunnel.preferredDriveLetter} is not available, using auto-select instead'),
                    duration: const Duration(seconds: 5),
                  ),
                );
              }
            }
          }
          
          // Show drive letter selection dialog if context is provided and no drive letter is selected yet
          // and auto-select is not enabled
          if (selectedDriveLetter == null && context != null && !tunnel.autoSelectDrive) {
            selectedDriveLetter = await showDialog<String>(
              context: context,
              builder: (context) => DriveLetterDialog(domain: domain),
            );
          }
          
          // If no drive letter was selected (auto-select or dialog was cancelled),
          // find an available drive letter automatically
          selectedDriveLetter ??= await _smbService.findAvailableDriveLetter();
          
          if (selectedDriveLetter.isEmpty) {
            LogService().error('No available drive letters for mounting SMB share');
            // Continue anyway, as the tunnel is still running
          } else {
            // Mount the SMB share
            LogService().info('About to mount SMB share for $domain:$port');
            final mounted = await _smbService.mountSmbShare(tunnel, selectedDriveLetter);
            LogService().info('SMB mount process initiated: $mounted for $domain:$port');
            
            // Immediately update connection status without waiting for verification
            LogService().info('Forcing connection status update for $domain:$port');
            await _cfService.checkSmbMountStatus(domain, port);
            
            // Log drive mount status
            final driveMounted = _smbService.isDomainMounted(domain);
            LogService().info('Drive mounting in progress: $driveMounted for $domain at $selectedDriveLetter:');
          }
        } catch (e) {
          // Log but don't fail if mounting has issues
          LogService().error('Error during SMB mounting process: $e');
          // Continue anyway - the tunnel may still be functional
        }
      }
      
      // Do a final check of running tunnel state
      await checkRunningTunnel();
      
      // Return true to indicate the forwarding process was started
      return true;
    } catch (e, stack) {
      _logger.e('Error starting forwarding: ${e.toString()}');
      LogService().error('Error starting forwarding: $e');
      LogService().error('Stack trace: $stack');
      return false;
    } finally {
      _processingTunnels.remove(domain);
      notifyListeners();
    }
  }

  Future<bool> stopForwarding(String domain) async {
    _processingTunnels.add(domain);
    notifyListeners();
    try {
      LogService().info('Stopping forwarding for $domain');
      
      // Find the tunnel by domain
      final tunnelIndex = _tunnels.indexWhere((t) => t.domain == domain);
      if (tunnelIndex == -1) {
        LogService().error('Tunnel not found for domain: $domain');
        return false;
      }
      
      final tunnel = _tunnels[tunnelIndex];
      
      // If this is an SMB tunnel and it's mounted, unmount it first
      if (tunnel.protocol == 'SMB' && _smbService.isDomainMounted(domain)) {
        final unmounted = await _smbService.unmountDrive(domain);
        if (!unmounted) {
          LogService().error('Failed to unmount drive for $domain');
          // Continue anyway to stop the tunnel
        } else {
          LogService().info('Drive unmounted successfully for $domain');
        }
      }
      
      // Stop the cloudflared tunnel
      final success = await _cfService.stopTunnel(tunnel);
      if (!success) {
        LogService().error('Failed to stop cloudflared tunnel for $domain');
        return false;
      }
      
      // Update the forwarding status
      _forwardingStatus.remove(domain);
      
      // Update the tunnel state
      final updatedTunnel = tunnel.copyWith(isRunning: false);
      await saveTunnel(updatedTunnel);
      
      return true;
    } catch (e) {
      _logger.e('Error stopping forwarding: ${e.toString()}');
      LogService().error('Error stopping forwarding: $e');
      return false;
    } finally {
      _processingTunnels.remove(domain);
      notifyListeners();
    }
  }

  Future<void> loadTunnels() async {
    try {
      final db = DatabaseService.instance.database;
      final List<Map<String, dynamic>> maps = await db.query('tunnels');
      _tunnels = List.generate(maps.length, (i) {
        return Tunnel.fromJson(maps[i]);
      });
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load tunnels: ${e.toString()}';
      _logger.e('Failed to load tunnels: ${e.toString()}');
      rethrow;
    }
  }

  Future<void> saveTunnel(Tunnel tunnel) async {
    try {
      final db = DatabaseService.instance.database;
      
      // Check if a tunnel with the same domain already exists (excluding the current tunnel being edited)
      final List<Map<String, dynamic>> existingTunnels = await db.query(
        'tunnels',
        where: 'domain = ? AND id != ?',
        whereArgs: [tunnel.domain, tunnel.id ?? -1],
      );
      
      if (existingTunnels.isNotEmpty) {
        throw Exception('A tunnel with domain "${tunnel.domain}" already exists');
      }

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
      
      // Removed automatic UI refresh when saving tunnels
      notifyListeners();
    } catch (e) {
      _error = 'Failed to save tunnel: ${e.toString()}';
      _logger.e('Failed to save tunnel: ${e.toString()}');
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
      
      final db = DatabaseService.instance.database;
      await db.delete(
        'tunnels',
        where: 'id = ?',
        whereArgs: [id],
      );
      _tunnels.removeWhere((t) => t.id == id);
      
      // Removed automatic UI refresh when deleting tunnels
      notifyListeners();
    } catch (e) {
      _error = 'Failed to delete tunnel: ${e.toString()}';
      _logger.e('Failed to delete tunnel: ${e.toString()}');
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
    } catch (e) {
      _error = 'Error starting tunnel: ${e.toString()}';
      _logger.e('Error starting tunnel: ${e.toString()}');
      rethrow;
    }
  }

  Future<void> stopTunnel(Tunnel tunnel) async {
    try {
      _error = null;
      await _cfService.stopPortForwarding(tunnel.port);
      final updatedTunnel = tunnel.copyWith(isRunning: false);
      await saveTunnel(updatedTunnel);
    } catch (e) {
      _error = 'Error stopping tunnel: ${e.toString()}';
      _logger.e('Error stopping tunnel: ${e.toString()}');
      rethrow;
    }
  }

  Future<void> initiateLogin() async {
    try {
      await _cfService.initiateLogin();
    } catch (e) {
      LogService().error('Failed to initiate login: $e');
    }
  }

  // Export tunnels to JSON string
  String exportTunnels() {
    try {
      final List<Map<String, dynamic>> tunnelsJson = _tunnels.map((t) => {
        'id': t.id,
        'domain': t.domain,
        'port': t.port,
        'protocol': t.protocol,
        'is_local': t.isLocal ? 1 : 0,
        'is_running': t.isRunning ? 1 : 0
      }).toList();
      return jsonEncode({'tunnels': tunnelsJson});
    } catch (e) {
      _error = 'Failed to export tunnels: ${e.toString()}';
      _logger.e('Failed to export tunnels: ${e.toString()}');
      return '{"error": "${e.toString()}"}';
    }
  }

  // Import tunnels from JSON string
  Future<void> importTunnels(String jsonStr) async {
    try {
      // First try to parse the JSON string
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      
      if (data.containsKey('tunnels')) {
        final List<dynamic> tunnelsJson = data['tunnels'];
        final List<Tunnel> newTunnels = tunnelsJson.map((t) {
          // Convert numeric id to string to ensure compatibility
          final id = t['id']?.toString();
          
          // Ensure all required fields are present and in correct format
          final Map<String, dynamic> tunnelMap = {
            'id': id != null ? int.tryParse(id) : null,
            'domain': t['domain']?.toString() ?? '',
            'port': t['port']?.toString() ?? '',
            'protocol': t['protocol']?.toString() ?? '',
            'is_local': t['is_local'] is bool ? (t['is_local'] ? 1 : 0) : (t['is_local'] ?? 0),
            'is_running': t['is_running'] is bool ? (t['is_running'] ? 1 : 0) : (t['is_running'] ?? 0)
          };
          
          return Tunnel.fromJson(tunnelMap);
        }).toList();

        // Save all new tunnels to database, skipping duplicates
        for (var tunnel in newTunnels) {
          try {
            // Check if tunnel with this domain already exists
            final existingTunnel = _tunnels.where(
              (t) => t.domain == tunnel.domain,
            ).isNotEmpty;
            
            if (existingTunnel) {
              LogService().info('Skipping import of duplicate tunnel for domain: ${tunnel.domain}');
            } else {
              await saveTunnel(tunnel);
            }
                    } catch (e) {
            LogService().warning('Failed to import tunnel for domain ${tunnel.domain}: ${e.toString()}');
            continue;
          }
        }
        
        await loadTunnels(); // Reload tunnels from database
        // Removed automatic UI refresh when importing tunnels
        // notifyListeners();
      }
    } catch (e) {
      _error = 'Failed to import tunnels: ${e.toString()}';
      _logger.e('Failed to import tunnels: ${e.toString()}');
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
    } catch (e) {
      _logger.e('Error during cleanup: ${e.toString()}');
    }
  }
}
