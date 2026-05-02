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
import '../services/secure_storage_service.dart';
import '../ui/smb_auth_dialog.dart';
import '../ui/admin_warning_dialog.dart';

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
      
      // Update tunnel states based on running processes in parallel
      await Future.wait(_tunnels.map((tunnel) async {
        final isRunning = runningProcesses.containsKey(tunnel.domain) &&
                         runningProcesses[tunnel.domain].toString() == tunnel.port.toString();
        
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

        // Also sync SMB mount state if applicable
        if (tunnel.protocol == 'SMB') {
          final isMounted = await _smbService.verifyDriveMountedForDomain(tunnel.domain);
          if (isMounted && !_smbService.isDomainMounted(tunnel.domain)) {
            // Re-track the drive if found in OS but not in memory
            final driveLetter = await _smbService.getDriveLetterFromOS(tunnel.domain);
            if (driveLetter != null) {
              _smbService.trackMountedDrive(tunnel.domain, driveLetter);
              LogService().info('Re-tracked SMB mount for ${tunnel.domain} on $driveLetter:');
            }
          }
        }
      }));
      
      LogService().info('Updated forwarding status map: $_forwardingStatus');
      
      // Get running tunnel info from cloudflared service
      _runningTunnel = await _cfService.getRunningTunnelInfo();
      LogService().info('Running tunnel info: $_runningTunnel');
      
    } catch (e, stack) {
      _logger.e('Error checking running tunnel: ${e.toString()}');
      LogService().error('Error checking running tunnel: $e');
      LogService().error('Stack trace: $stack');
    } finally {
      notifyListeners();
    }
  }

  Future<bool> startForwarding(String domain, String port, {BuildContext? context}) async {
    try {
      LogService().info('Starting port forwarding for $domain:$port');
      
      // Check if this specific connection is already being processed
      if (_processingTunnels.contains(domain)) {
        LogService().warning('Connection for $domain is already being processed');
        return false;
      }
      
      _processingTunnels.add(domain);
      notifyListeners();
      
      // Find the tunnel in the list
      final tunnelIndex = _tunnels.indexWhere((t) => t.domain == domain);
      if (tunnelIndex == -1) {
        LogService().error('Tunnel not found for $domain');
        return false;
      }
      
      Tunnel tunnel = _tunnels[tunnelIndex];
      
      // Check if the tunnel is already running
      if (tunnel.isRunning) {
        LogService().warning('Tunnel for $domain is already running');
        return true;
      }

      // Variables to hold SMB gathering data
      String? smbUsername;
      String? smbPassword;
      String? selectedDriveLetter;
      bool shouldSaveCredentials = tunnel.saveCredentials;

      // 1. Gather all required inputs FIRST before starting any background processes
      if (tunnel.protocol == 'SMB') {
        try {
          // Check if running as admin and warn the user
          final isAdmin = await _smbService.isRunningAsAdmin();
          if (isAdmin && context != null && context.mounted) {
            await showDialog(
              context: context,
              builder: (context) => const AdminWarningDialog(),
            );
          }

          if (tunnel.saveCredentials) {
            smbUsername = await SecureStorageService.getUsername(tunnel.domain);
            smbPassword = await SecureStorageService.getPassword(tunnel.domain);
          }

          // If we don't have credentials, we need to ask the user.
          if (smbUsername == null || smbPassword == null) {
            if (context != null && context.mounted) {
              final result = await showDialog<Map<String, dynamic>>(
                context: context,
                builder: (context) => SmbAuthDialog(tunnel: tunnel),
              );

              if (result != null) {
                smbUsername = result['username'];
                smbPassword = result['password'];
                shouldSaveCredentials = result['saveCredentials'];
                // Update the tunnel's saveCredentials setting in memory
                tunnel = tunnel.copyWith(saveCredentials: shouldSaveCredentials);
              } else {
                // User cancelled the dialog
                LogService().warning('SMB authentication cancelled by user.');
                return false;
              }
            } else {
              LogService().error('Cannot ask for SMB credentials without a build context.');
              return false;
            }
          }
          
          // Drive letter selection logic
          if (!tunnel.autoSelectDrive && tunnel.preferredDriveLetter != null) {
            final availableDriveLetters = await _smbService.getAvailableDriveLetters();
            if (availableDriveLetters.contains(tunnel.preferredDriveLetter)) {
              selectedDriveLetter = tunnel.preferredDriveLetter;
              LogService().info('Using preferred drive letter: $selectedDriveLetter');
            } else {
              LogService().warning('Preferred drive letter ${tunnel.preferredDriveLetter} is not available, falling back to auto-select');
              if (context != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Preferred drive letter ${tunnel.preferredDriveLetter} is not available, using auto-select instead'),
                    duration: const Duration(seconds: 5),
                  ),
                );
              }
            }
          }
          
          if (selectedDriveLetter == null && context != null && !tunnel.autoSelectDrive && context.mounted) {
            selectedDriveLetter = await showDialog<String>(
              context: context,
              builder: (context) => DriveLetterDialog(domain: domain),
            );
            if (selectedDriveLetter == null) {
              // User cancelled drive letter dialog
              LogService().warning('Drive letter selection cancelled by user.');
              return false;
            }
          }
          
          selectedDriveLetter ??= await _smbService.findAvailableDriveLetter();
          
          if (selectedDriveLetter.isEmpty) {
            LogService().error('No available drive letters for mounting SMB share');
            if (context != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('No available drive letters to mount SMB share.'),
                  duration: Duration(seconds: 5),
                ),
              );
            }
            return false;
          }
        } catch (e) {
          LogService().error('Error during SMB input gathering process: $e');
          return false;
        }
      }
      
      // 2. Start the cloudflared tunnel
      final success = await _cfService.startTunnel(tunnel);
      if (!success) {
        LogService().error('Failed to start cloudflared tunnel for $domain:$port');
        return false;
      }
      
      // Update the forwarding status immediately 
      _forwardingStatus[domain] = port;
      
      // Update the tunnel status
      Tunnel updatedTunnel = tunnel.copyWith(isRunning: true);
      await saveTunnel(updatedTunnel);
      
      // 3. Mount SMB share if applicable
      if (tunnel.protocol == 'SMB') {
        try {
          // Guard: ensure we have a valid drive letter before force-unwrapping
          if (selectedDriveLetter == null || selectedDriveLetter.isEmpty) {
            LogService().error('No valid drive letter available for SMB mount.');
            await _cfService.stopTunnel(updatedTunnel);
            _forwardingStatus.remove(domain);
            updatedTunnel = updatedTunnel.copyWith(isRunning: false);
            await saveTunnel(updatedTunnel);
            return false;
          }
          LogService().info('About to mount SMB share for $domain:$port on $selectedDriveLetter');
          final mounted = await _smbService.mountSmbShare(updatedTunnel, selectedDriveLetter, smbUsername!, smbPassword!);
          LogService().info('SMB mount process initiated: $mounted for $domain:$port');

          if (mounted) {
            // Save credentials to secure storage if requested
            if (shouldSaveCredentials) {
              await SecureStorageService.saveCredentials(tunnel.domain, smbUsername!, smbPassword!);
              LogService().info('Saved credentials for ${tunnel.domain} to secure storage');
            }
            
            final isAccessible = await _smbService.verifyDriveAccessibility(selectedDriveLetter);
            LogService().info('SMB mount at $selectedDriveLetter: accessibility check returned: $isAccessible');
            if (!isAccessible) {
               LogService().warning('SMB mount for $domain may not be accessible.');
            }
          } else {
             LogService().error('SMB mount process failed for $domain. Stopping tunnel.');
             await _cfService.stopTunnel(updatedTunnel);
             _forwardingStatus.remove(domain);
             updatedTunnel = updatedTunnel.copyWith(isRunning: false);
             await saveTunnel(updatedTunnel);
             return false;
          }
        } catch (e) {
          LogService().error('Error during SMB mounting process: $e');
          await _cfService.stopTunnel(updatedTunnel);
          _forwardingStatus.remove(domain);
          updatedTunnel = updatedTunnel.copyWith(isRunning: false);
          await saveTunnel(updatedTunnel);
          return false;
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
    try {
      LogService().info('Stopping forwarding for $domain');
      
      // Check if this specific connection is already being processed
      if (_processingTunnels.contains(domain)) {
        LogService().warning('Connection for $domain is already being processed');
        return false;
      }
      
      _processingTunnels.add(domain);
      notifyListeners();
      
      // Find the tunnel by domain
      final tunnelIndex = _tunnels.indexWhere((t) => t.domain == domain);
      if (tunnelIndex == -1) {
        LogService().error('Tunnel not found for domain: $domain');
        return false;
      }
      
      final tunnel = _tunnels[tunnelIndex];
      
      // Check if the tunnel is already stopped
      if (!tunnel.isRunning) {
        LogService().warning('Tunnel for $domain is already stopped');
        return true;
      }
      
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

  // startTunnel and stopTunnel are legacy methods superseded by
  // startForwarding / stopForwarding. Removed to avoid confusion.

  Future<void> initiateLogin() async {
    try {
      await _cfService.initiateLogin();
    } catch (e) {
      LogService().error('Failed to initiate login: $e');
    }
  }

  // Export tunnels to JSON string
  // NOTE: is_running is always exported as 0 — a tunnel cannot be "running"
  // on an import target machine; it must be started explicitly.
  String exportTunnels() {
    try {
      final List<Map<String, dynamic>> tunnelsJson = _tunnels.map((t) => {
        'id': t.id,
        'domain': t.domain,
        'port': t.port,
        'protocol': t.protocol,
        'is_local': t.isLocal ? 1 : 0,
        'is_running': 0, // always 0: running state is not portable
        'remote_path': t.remotePath,
        'preferred_drive_letter': t.preferredDriveLetter,
        'auto_select_drive': t.autoSelectDrive ? 1 : 0,
        'save_credentials': t.saveCredentials ? 1 : 0,
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
      // Unmount any active SMB drives first
      for (final tunnel in _tunnels) {
        if (tunnel.protocol == 'SMB' && tunnel.isRunning && _smbService.isDomainMounted(tunnel.domain)) {
          await _smbService.unmountDrive(tunnel.domain);
        }
      }

      // Stop all cloudflared port forwardings
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
