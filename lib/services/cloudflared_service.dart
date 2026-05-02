// lib/services/cloudflared_service.dart

import 'dart:io';
import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import '../models/tunnel.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'dart:math';
import 'dart:async';
import '../services/log_service.dart';

class CloudflaredService {
  final Logger _logger = Logger();
  static final CloudflaredService _instance = CloudflaredService._internal();
  factory CloudflaredService() => _instance;

  CloudflaredService._internal();

  final Map<int, Process> _processes = {};
  final Map<String, Tunnel> _activeTunnels = {};
  final Map<int, int> _cloudflaredPids = {};
  // Enhanced tracking with unique connection identifiers
  final Map<String, int> _connectionPids = {}; // domain:port -> pid
  final Map<String, Process> _connectionProcesses = {}; // domain:port -> process
  final Map<String, String> _connectionStates = {}; // domain:port -> state

  // Helper method to generate unique connection key
  String _getConnectionKey(String domain, String port) {
    return '$domain:$port';
  }

  // Helper method to check if a connection is running
  bool _isConnectionRunning(String domain, String port) {
    final key = _getConnectionKey(domain, port);
    return _connectionStates[key] == 'running';
  }

  // Helper method to set connection state
  void _setConnectionState(String domain, String port, String state) {
    final key = _getConnectionKey(domain, port);
    _connectionStates[key] = state;
    LogService().info('Connection $key state set to: $state');
  }

  // Helper method to clean up connection resources
  void _cleanupConnection(String domain, String port) {
    final key = _getConnectionKey(domain, port);
    _connectionPids.remove(key);
    _connectionProcesses.remove(key);
    _connectionStates.remove(key);
    LogService().info('Cleaned up resources for connection: $key');
  }

  // Helper method to validate connection state before operations
  bool _validateConnectionState(String domain, String port, String operation) {
    final key = _getConnectionKey(domain, port);
    final currentState = _connectionStates[key];
    
    // For new connections (null state), allow start operations and stop operations
    if (currentState == null) {
      if (operation == 'start') {
        LogService().info('New connection $key - allowing start operation');
        return true;
      } else if (operation == 'stop') {
        LogService().info('Connection $key not tracked - allowing stop operation (may be legacy connection)');
        return true;
      } else {
        LogService().warning('Connection $key not found for $operation operation');
        return false;
      }
    }
    
    // Validate state transitions
    switch (operation) {
      case 'start':
        if (currentState == 'running') {
          LogService().warning('Connection $key is already running, cannot start');
          return false;
        }
        if (currentState == 'starting') {
          LogService().warning('Connection $key is already starting, cannot start again');
          return false;
        }
        break;
      case 'stop':
        if (currentState != 'running') {
          LogService().warning('Connection $key is not running (state: $currentState), cannot stop');
          return false;
        }
        break;
      case 'restart':
        // Allow restart from any state
        break;
      default:
        LogService().warning('Unknown operation: $operation');
        return false;
    }
    
    return true;
  }

  // Helper method to get connection status
  String getConnectionStatus(String domain, String port) {
    final key = _getConnectionKey(domain, port);
    return _connectionStates[key] ?? 'unknown';
  }

  // Helper method to get all active connections
  Map<String, String> getAllConnectionStates() {
    return Map.from(_connectionStates);
  }

  // Check if cloudflared is installed
  Future<bool> isCloudflaredInstalled() async {
    try {
      final result = await Process.run('cloudflared', ['--version']);
      return result.exitCode == 0;
    } catch (e) {
      _logger.e('Cloudflared not found: $e');
      return false;
    }
  }

  // Check cloudflared authentication status
  Future<bool> checkAuthenticationStatus() async {
    try {
      LogService().info('Checking cloudflared authentication status...');
      ProcessResult result = await Process.run('cloudflared', ['tunnel', 'list'], runInShell: true);
      
      final stderr = result.stderr.toString();
      if (stderr.contains('Cannot determine default origin certificate path') ||
          stderr.contains('Error locating origin cert')) {
        LogService().warning('Cloudflared is not authenticated. Please use the login button to authenticate.');
        return false;
      }
      
      return result.exitCode == 0;
    } catch (e) {
      LogService().error('Error checking authentication status: $e');
      return false;
    }
  }

  // Get running tunnel info
  Future<Map<String, String>?> getRunningTunnelInfo() async {
    try {
      final services = await getRunningWindowsServices();
      LogService().info('Raw services data: $services');
      
      if (services.isEmpty) {
        LogService().info('No cloudflared services found');
        return null;
      }

      bool isUserAuthenticated = await checkAuthenticationStatus();
      if (!isUserAuthenticated) {
        LogService().warning('Cloudflared is not authenticated. Some features will be limited.');
        LogService().info('User can still view tunnel IDs but names will not be available.');
      }

      for (final service in services) {
        final path = service['PathName'] ?? '';
        LogService().info('Processing service PathName: $path');
        
        if (path.isEmpty) {
          LogService().info('Empty PathName, skipping...');
          continue;
        }

        final tokenMatch = RegExp(r'--token\s+([^\s"]+)').firstMatch(path);
        LogService().info('Token match found: ${tokenMatch != null}');
        
        if (tokenMatch != null) {
          LogService().info('Token match groups: ${tokenMatch.groupCount}, First group: ${tokenMatch.group(1)}');
        }
        
        if (tokenMatch == null) continue;

        final token = tokenMatch.group(1);
        LogService().info('Extracted token (first 20 chars): ${token?.substring(0, min(20, token.length))}...');
        
        if (token == null) continue;

        final tunnelId = await _extractTunnelIdFromToken(token);
        LogService().info('Extracted tunnel ID: $tunnelId');
        
        if (tunnelId != null) {
          // If user is not authenticated, return just the tunnel ID
          if (!isUserAuthenticated) {
            final result = {
              'id': tunnelId,
              'name': 'Login required to view name',
              'requires_login': 'true'
            };
            LogService().info('Returning partial tunnel info (unauthenticated): $result');
            return result;
          }

          // If authenticated, try to get full tunnel info
          LogService().info('Attempting to list tunnels...');
          final tunnels = await listTunnels();
          LogService().info('Available tunnels from Cloudflare: $tunnels');
          
          LogService().info('Looking for tunnel with ID: $tunnelId');
          final tunnel = tunnels.firstWhere(
            (t) => t['id'].toString().toLowerCase() == tunnelId.toLowerCase(),
            orElse: () {
              LogService().info('No matching tunnel found with ID: $tunnelId');
              return <String, String>{};
            },
          );
          LogService().info('Matched tunnel details: $tunnel');

          if (tunnel.isNotEmpty) {
            final result = {
              'id': tunnelId,
              'name': tunnel['name']?.toString() ?? 'Unnamed Tunnel',
            };
            LogService().info('Returning tunnel info: $result');
            return result;
          } else {
            // If we can't find the tunnel name but have the ID, return partial info
            final result = {
              'id': tunnelId,
              'name': 'Unknown Tunnel',
            };
            LogService().info('Returning partial tunnel info: $result');
            return result;
          }
        }
      }
      LogService().info('No valid tunnel found in any service, returning null');
      return null;
    } catch (e) {
      LogService().error('Error getting running tunnel info: ${e.toString()}');
      return null;
    }
  }

  // Start port forwarding
  Future<bool> startPortForwarding(String domain, String port) async {
    try {
      final portNum = int.parse(port);
      final connectionKey = _getConnectionKey(domain, port);
      LogService().info('Starting port forwarding process...');
      LogService().info('Domain: $domain, Port: $port, Connection Key: $connectionKey');
      
      // Validate connection state before starting
      if (!_validateConnectionState(domain, port, 'start')) {
        return false;
      }
      
      // Check if this specific connection is already running
      if (_isConnectionRunning(domain, port)) {
        LogService().warning('Connection $connectionKey is already running');
        return true; // Already running
      }
      
      // Check if port is available (but only if no other connection is using it)
      if (!await checkPortAvailability(portNum)) {
        // Check if the port is being used by another connection
        final conflictingConnection = _connectionPids.entries
            .where((entry) => entry.key != connectionKey)
            .any((entry) => entry.value != 0);
        
        if (conflictingConnection) {
          LogService().error('ERROR: Port $port is already in use by another connection');
          return false;
        }
        
        // If port is in use but not by our connections, it might be an orphaned process
        LogService().warning('Port $port is in use by an external or orphaned process. Attempting to kill it...');
        await _killProcessOnPort(portNum);
        
        // Wait a moment for the OS to free the port
        await Future.delayed(const Duration(milliseconds: 1500));
        
        if (!await checkPortAvailability(portNum)) {
          LogService().error('ERROR: Port $port is still in use after attempted kill.');
          return false;
        }
      }

      // Get cloudflared path
      final cloudflaredPath = await _getCloudflaredPath();
      if (cloudflaredPath == null) {
        LogService().error('ERROR: Could not find cloudflared executable');
        return false;
      }
      LogService().info('Found cloudflared at: $cloudflaredPath');

      // Set connection state to starting
      _setConnectionState(domain, port, 'starting');
      
      final process = await Process.start(
        cloudflaredPath,
        [
          'access', 'tcp',
          '--hostname', domain,
          '--url', 'tcp://localhost:$port'
        ],
        runInShell: false,
      );
      
      final processId = process.pid;
      _connectionProcesses[connectionKey] = process;
      
      // Track this specific connection
      _connectionPids[connectionKey] = processId;
      _cloudflaredPids[portNum] = processId; // Keep legacy tracking for compatibility
      LogService().info('Started cloudflared process for connection $connectionKey with PID $processId');
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Verify the connection is working
      if (!await checkPortAvailability(portNum)) {
        LogService().system('Tunnel started successfully (port is in use)');
        _setConnectionState(domain, port, 'running');
        _activeTunnels[domain] = Tunnel(
          domain: domain,
          port: port,
          protocol: 'tcp',
          isRunning: true
        );
        return true;
      } else {
        LogService().error('ERROR: Tunnel failed to start (port still available)');
        _setConnectionState(domain, port, 'failed');
        _cleanupConnection(domain, port);
        return false;
      }
    } catch (e) {
      LogService().error('ERROR: Failed to start port forwarding: $e');
      return false;
    }
  }

  int _startHiddenProcess(String command) {
    final lpApplicationName = command.toNativeUtf16();
    final si = calloc<STARTUPINFO>();
    final pi = calloc<PROCESS_INFORMATION>();
    si.ref.cb = sizeOf<STARTUPINFO>();
    si.ref.dwFlags = STARTF_USESHOWWINDOW;
    si.ref.wShowWindow = SW_HIDE;

    try {
      if (CreateProcess(
            nullptr,
            lpApplicationName,
            nullptr,
            nullptr,
            FALSE,
            CREATE_NO_WINDOW,
            nullptr,
            nullptr,
            si,
            pi,
          ) ==
          FALSE) {
        final error = GetLastError();
        LogService().error('Failed to create process: $error');
        return 0;
      }
      return pi.ref.dwProcessId;
    } finally {
      free(lpApplicationName);
      free(si);
      free(pi);
    }
  }

  Future<String?> _getCloudflaredPath() async {
    try {
      // Check common installation paths
      final possiblePaths = [
        r'C:\Program Files\cloudflared\cloudflared.exe',
        r'C:\Program Files (x86)\cloudflared\cloudflared.exe',
        'cloudflared',  // If in PATH
      ];

      for (final path in possiblePaths) {
        try {
          final result = await Process.run(path, ['--version']);
          if (result.exitCode == 0) {
            return path;
          }
        } catch (_) {
          continue;
        }
      }
      
      return null;
    } catch (e) {
      _logger.e('Error finding cloudflared path: $e');
      return null;
    }
  }

  // Stop port forwarding
  Future<void> stopPortForwarding(String port) async {
    try {
      final portNum = int.parse(port);
      LogService().info('Attempting to stop port forwarding on port $port');

      // Find the connection using this port
      final connectionEntry = _connectionPids.entries
          .where((entry) => entry.key.endsWith(':$port'))
          .firstOrNull;
      
      if (connectionEntry != null) {
        final connectionKey = connectionEntry.key;
        final pid = connectionEntry.value;
        LogService().info('Found connection $connectionKey with PID $pid. Terminating...');
        
        // Set connection state to stopping
        _setConnectionState(connectionKey.split(':')[0], port, 'stopping');
        
        final process = _connectionProcesses[connectionKey];
        bool killed = false;
        if (process != null) {
          killed = process.kill(ProcessSignal.sigterm);
        } else {
          killed = Process.killPid(pid, ProcessSignal.sigterm);
        }

        if (!killed) {
           LogService().warning('Graceful kill failed, attempting forced kill for PID $pid');
           if (process != null) {
              killed = process.kill(ProcessSignal.sigkill);
           } else {
              killed = Process.killPid(pid, ProcessSignal.sigkill);
           }
        }

        if (killed) {
          LogService().system('Process with PID $pid terminated successfully.');
          _cleanupConnection(connectionKey.split(':')[0], port);
          _cloudflaredPids.remove(portNum);
          _processes.remove(portNum);
          _activeTunnels.removeWhere((domain, tunnel) => tunnel.port == port);

          // Verify port is now available.
          await Future.delayed(const Duration(milliseconds: 200));
          if (await checkPortAvailability(portNum)) {
            LogService().system('Port $port is now available.');
          } else {
            LogService().warning('Port $port is still in use after terminating process.');
          }
          return;
        } else {
          LogService().error('Failed to kill process with PID $pid.');
        }
      }

      // Fallback to legacy PID tracking
      if (_cloudflaredPids.containsKey(portNum)) {
        final pid = _cloudflaredPids[portNum]!;
        LogService().info('Found stored PID $pid for port $port. Terminating...');
        
        bool killed = Process.killPid(pid, ProcessSignal.sigterm);
        if (!killed) {
          killed = Process.killPid(pid, ProcessSignal.sigkill);
        }

        if (killed) {
          LogService().system('Process with PID $pid terminated successfully.');
          _cloudflaredPids.remove(portNum);
          _processes.remove(portNum);
          _activeTunnels.removeWhere((domain, tunnel) => tunnel.port == port);

          // Verify port is now available.
          await Future.delayed(const Duration(milliseconds: 200));
          if (await checkPortAvailability(portNum)) {
            LogService().system('Port $port is now available.');
          } else {
            LogService().warning('Port $port is still in use after terminating process.');
          }
          return;
        } else {
          LogService().error('Failed to kill process with PID $pid.');
        }
      }

      LogService().warning('No stored PID for port $port. Could not stop forwarding.');

    } catch (e, stack) {
      _logger.e('Error stopping port forwarding: $e\n$stack');
      LogService().error('Error stopping port forwarding: $e');
      LogService().error('Stack trace: $stack');
    }
  }

  Future<bool> startTunnel(Tunnel tunnel) async {
    try {
      final connectionKey = _getConnectionKey(tunnel.domain, tunnel.port);
      LogService().info('Starting tunnel for ${tunnel.domain}:${tunnel.port}...');
      
      // Check if this specific connection is already running
      if (_isConnectionRunning(tunnel.domain, tunnel.port)) {
        LogService().warning('Tunnel $connectionKey is already running');
        return true;
      }
      
      // Check if cloudflared is installed
      if (!await isCloudflaredInstalled()) {
        LogService().error('Cloudflared is not installed');
        return false;
      }
      
      // Start the tunnel
      final success = await startPortForwarding(tunnel.domain, tunnel.port);
      if (!success) {
        LogService().error('Failed to start port forwarding for ${tunnel.domain}:${tunnel.port}');
        return false;
      }
      
      LogService().info('Tunnel started successfully for ${tunnel.domain}:${tunnel.port}');
      return true;
    } catch (e) {
      LogService().error('Error starting tunnel: $e');
      return false;
    }
  }

  Future<bool> stopTunnel(Tunnel tunnel) async {
    try {
      final connectionKey = _getConnectionKey(tunnel.domain, tunnel.port);
      LogService().info('Stopping tunnel for ${tunnel.domain}:${tunnel.port}...');
      
      // Validate connection state before stopping
      if (!_validateConnectionState(tunnel.domain, tunnel.port, 'stop')) {
        // If validation fails, still try to stop the port forwarding
        // as it might be a legacy connection not tracked in our state
        LogService().warning('Connection state validation failed, attempting to stop anyway...');
      }
      
      // Check if this specific connection is running (only if we have state tracking)
      if (_connectionStates.containsKey(connectionKey) && !_isConnectionRunning(tunnel.domain, tunnel.port)) {
        LogService().warning('Tunnel $connectionKey is not running according to state tracking');
        return true;
      }
      
      // Stop the tunnel
      await stopPortForwarding(tunnel.port);
      
      LogService().info('Tunnel stopped successfully for ${tunnel.domain}:${tunnel.port}');
      return true;
    } catch (e) {
      LogService().error('Error stopping tunnel: $e');
      return false;
    }
  }

  bool isTunnelRunning(Tunnel tunnel) {
    if (!tunnel.isLocal) return false;
    // Check if this specific connection is running
    return _isConnectionRunning(tunnel.domain, tunnel.port);
  }

  Future<String> getLoginCommand() async {
    try {
      ProcessResult result = await Process.run('cloudflared', ['tunnel', 'login'], runInShell: true);
      return result.stdout.toString().trim();
    } catch (e) {
      _logger.e('Error getting login command: $e');
      return '';
    }
  }

  Future<bool> checkPortAvailability(int port) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await server.close();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _killProcessOnPort(int port) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('netstat', ['-aon']);
        final lines = result.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.contains(':$port ') && line.contains('LISTENING')) {
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.isNotEmpty) {
              final pid = int.tryParse(parts.last);
              if (pid != null && pid > 0) {
                LogService().info('Killing process $pid listening on port $port');
                await Process.run('taskkill', ['/F', '/PID', pid.toString()]);
              }
            }
          }
        }
      } else {
        final result = await Process.run('lsof', ['-ti:$port']);
        final pids = result.stdout.toString().trim().split('\n');
        for (final pidStr in pids) {
          final pid = int.tryParse(pidStr);
          if (pid != null && pid > 0) {
            LogService().info('Killing process $pid listening on port $port');
            await Process.run('kill', ['-9', pid.toString()]);
          }
        }
      }
    } catch (e) {
      LogService().error('Error attempting to kill process on port $port: $e');
    }
  }

  Future<Map<String, dynamic>> createTunnel(String name) async {
    try {
      if (name.isEmpty) {
        return {'success': false, 'error': 'Tunnel name cannot be empty'};
      }
      
      // Add validation for existing tunnels
      final existingTunnels = await listTunnels();
      if (existingTunnels.any((t) => t['name'] == name)) {
        return {'success': false, 'error': 'Tunnel with this name already exists'};
      }

      ProcessResult result = await Process.run('cloudflared', ['tunnel', 'create', name], runInShell: true);
      if (result.exitCode != 0) {
        _logger.e('Failed to create tunnel: ${result.stderr}');
        return {'success': false, 'error': result.stderr.toString()};
      }

      // Get the tunnel ID and credentials file path from the output
      String output = result.stdout.toString();
      RegExp tunnelIdRegex = RegExp(r'Created tunnel ([\w-]+)');
      var match = tunnelIdRegex.firstMatch(output);
      String? tunnelId = match?.group(1);

      if (tunnelId == null) {
        return {'success': false, 'error': 'Could not parse tunnel ID'};
      }

      // Create config file for the tunnel
      final configSuccess = await _createTunnelConfig(tunnelId);
      if (!configSuccess) {
        return {'success': false, 'error': 'Failed to create tunnel configuration'};
      }

      return {
        'success': true,
        'tunnelId': tunnelId,
        'output': output,
      };
    } catch (e) {
      _logger.e('Error creating tunnel: $e');
      return {'success': false, 'error': 'Failed to create tunnel: ${e.toString()}'};
    }
  }

  Future<bool> _createTunnelConfig(String tunnelId) async {
    try {
      // Get the default config directory
      final configDir = await _getConfigDir();
      final configPath = p.join(configDir.path, '$tunnelId.yml');

      // Create basic config file
      final configFile = File(configPath);
      await configFile.writeAsString('''
tunnel: $tunnelId
credentials-file: ${p.join(configDir.path, '$tunnelId.json')}
ingress:
  - hostname: "*"
    service: http_status:404
''');

      return true;
    } catch (e) {
      _logger.e('Error creating tunnel config: $e');
      return false;
    }
  }

  Future<Directory> _getConfigDir() async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) throw Exception('APPDATA environment variable not found');
      final dir = Directory(p.join(appData, 'cloudflared'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } else {
      final home = Platform.environment['HOME'];
      if (home == null) throw Exception('HOME environment variable not found');
      final dir = Directory(p.join(home, '.cloudflared'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  Future<List<Map<String, String>>> listTunnels() async {
    try {
      LogService().info('Executing cloudflared tunnel list command...');
      ProcessResult result = await Process.run('cloudflared', ['tunnel', 'list', '--output', 'json'], runInShell: true).timeout(const Duration(seconds: 15));
      
      LogService().info('Tunnel list command exit code: ${result.exitCode}');
      LogService().info('Tunnel list stdout: ${result.stdout}');
      
      final stderr = result.stderr.toString();
      if (stderr.isNotEmpty) {
        LogService().info('Tunnel list stderr: $stderr');
        
        // Check for the specific origin certificate error
        if (stderr.contains('Cannot determine default origin certificate path') ||
            stderr.contains('Error locating origin cert')) {
          LogService().error('Cloudflared is not authenticated. Please run cloudflared login first.');
          throw Exception('Cloudflared authentication required. Please run cloudflared login first.');
        }
      }

      if (result.exitCode != 0) {
        LogService().error('Failed to list tunnels: $stderr');
        return [];
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        LogService().info('Tunnel list output is empty');
        return [];
      }

      List<dynamic> tunnels = json.decode(output);
      LogService().info('Parsed ${tunnels.length} tunnels from JSON');
      
      final mapped = tunnels.map((tunnel) {
        final mapped = {
          'id': tunnel['id'] as String,
          'name': tunnel['name'] as String,
          'url': tunnel['url'] as String? ?? '',
        };
        LogService().info('Mapped tunnel: $mapped');
        return mapped;
      }).toList();
      
      LogService().info('Returning ${mapped.length} mapped tunnels');
      return mapped;
    } catch (e, stack) {
      LogService().error('Error listing tunnels: $e');
      LogService().error('Stack trace: $stack');
      
      // If this is an authentication error, rethrow it so we can handle it specially
      if (e.toString().contains('Cloudflared authentication required')) {
        rethrow;
      }
      return [];
    }
  }

  Future<bool> routeTunnel(String tunnelId, String domain) async {
    try {
      ProcessResult result = await Process.run(
        'cloudflared',
        ['tunnel', 'route', 'dns', tunnelId, domain],
        runInShell: true,
      );
      
      if (result.exitCode != 0) {
        _logger.e('Failed to route tunnel: ${result.stderr}');
        return false;
      }
      return true;
    } catch (e) {
      _logger.e('Error routing tunnel: $e');
      return false;
    }
  }

  Future<bool> deleteTunnel(String tunnelId) async {
    try {
      ProcessResult result = await Process.run(
        'cloudflared',
        ['tunnel', 'delete', tunnelId],
        runInShell: true,
      );
      
      if (result.exitCode != 0) {
        _logger.e('Failed to delete tunnel: ${result.stderr}');
        return false;
      }
      return true;
    } catch (e) {
      _logger.e('Error deleting tunnel: $e');
      return false;
    }
  }

  Future<int> findNextAvailablePort(int startPort) async {
    int port = startPort;
    while (!(await checkPortAvailability(port))) {
      port++;
    }
    return port;
  }

  Future<Map<String, dynamic>?> getLocalTunnelInfo() async {
    try {
      // Get the config directory
      final configDir = await _getConfigDir();
      
      // List all config files
      final List<FileSystemEntity> files = await configDir.list().toList();
      
      // Look for .yml files (tunnel configs)
      for (var file in files) {
        if (file.path.endsWith('.yml')) {
          final configFile = File(file.path);
          final content = await configFile.readAsString();
          
          // Parse the tunnel ID from the config
          final RegExp tunnelRegex = RegExp(r'tunnel:\s*([a-zA-Z0-9-]+)');
          final match = tunnelRegex.firstMatch(content);
          
          if (match != null) {
            final tunnelId = match.group(1);
            if (tunnelId != null) {
              // Get tunnel details from Cloudflare
              final tunnels = await listTunnels();
              final tunnel = tunnels.firstWhere(
                (t) => t['id'] == tunnelId,
                orElse: () => {},
              );
              
              if (tunnel.isNotEmpty) {
                // Parse ingress rules
                List<Map<String, String>> ingressRules = [];
                final ingressRegex = RegExp(
                  r'hostname:\s*"([^"]+)".*?\n\s*service:\s*([^\n]+)',
                  multiLine: true,
                );
                
                final matches = ingressRegex.allMatches(content);
                for (var m in matches) {
                  if (m.group(1) != '*') { // Skip catch-all rule
                    ingressRules.add({
                      'hostname': m.group(1)!,
                      'service': m.group(2)!.trim(),
                    });
                  }
                }

                return {
                  'id': tunnel['id']!,
                  'name': tunnel['name']!,
                  'domain': tunnel['url'] ?? 'No domain configured',
                  'config_file': file.path,
                  'ingress_rules': ingressRules,
                };
              }
            }
          }
        }
      }
      return null;
    } catch (e) {
      _logger.e('Error getting local tunnel info: $e');
      return null;
    }
  }

  Future<void> detectRunningTunnel() async {
    try {
      // Get local tunnel info
      final localTunnel = await getLocalTunnelInfo();
      if (localTunnel == null) return;

      // Check if cloudflared is running
      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('powershell', ['-Command', 'Get-Process cloudflared -ErrorAction SilentlyContinue'], runInShell: true);
      } else {
        result = await Process.run('pgrep', ['cloudflared']);
      }

      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        // Found running cloudflared process
        _logger.i('Detected running cloudflared process');
        
        // Check if the tunnel is actually running by trying to connect
        final isRunning = await _checkTunnelConnection(localTunnel['domain']);
        if (isRunning) {
          // Add to processes map with a dummy process
          // We can't get the actual Process object for an existing process
          final dummyProcess = await Process.start('cmd', ['/c', 'echo dummy']);
          _processes[-1] = dummyProcess;
          _logger.i('Successfully detected and tracked running tunnel: ${localTunnel['domain']}');
        }
      }
    } catch (e) {
      _logger.e('Error detecting running tunnel: $e');
    }
  }

  Future<bool> _checkTunnelConnection(String domain) async {
    try {
      // First check if the port is in use
      final portNum = int.parse(_activeTunnels[domain]?.port ?? '0');
      if (portNum > 0 && await checkPortAvailability(portNum)) {
        return false;
      }
      return true;
    } catch (e) {
      LogService().error('Error checking tunnel connection: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getRunningWindowsServices() async {
    try {
      LogService().info('Executing PowerShell command to get services...');
      final command = [
        '-Command',
        r"Get-CimInstance Win32_Service | Where-Object { $_.PathName -like '*cloudflared*' }" r" | Select-Object @{Name='Name';Expression={$_.Name}},@{Name='PathName';Expression={$_.PathName}} | ConvertTo-Json -Compress"
      ];
      
      LogService().info('Full command: powershell ${command.join(' ')}');
      
      final result = await Process.run(
        'powershell',
        command,
        runInShell: true,
      ).timeout(const Duration(seconds: 10));

      LogService().info('Command executed. Exit code: ${result.exitCode}');
      final output = result.stdout.toString().trim();
      LogService().info('Raw output: $output');

      if (result.exitCode != 0) {
        LogService().error('PowerShell command failed with exit code ${result.exitCode}');
        return [];
      }

      if (output.isEmpty) {
        LogService().warning('No cloudflared services found in output');
        return [];
      }

      try {
        dynamic decoded = json.decode(output);
        List<dynamic> services = decoded is List ? decoded : [decoded];
        
        LogService().info('Parsed ${services.length} services');
        
        final mappedServices = services.map((s) {
          final pathName = s['PathName']?.toString() ?? '';
          final name = s['Name']?.toString() ?? '';
          
          LogService().info('Processing service:');
          LogService().info('  Name: $name');
          LogService().info('  PathName: $pathName');
          
          return {
            'name': name,
            'PathName': pathName, // Changed from 'path' to 'PathName'
          };
        }).toList();

        LogService().info('Mapped services: $mappedServices');
        return mappedServices;
      } catch (e, stack) {
        LogService().error('JSON parsing failed: $e');
        LogService().error('Stack trace: $stack');
        LogService().error('Raw output that failed to parse: $output');
        return [];
      }
    } catch (e, stack) {
      LogService().error('Error getting Windows services: $e');
      LogService().error('Stack trace: $stack');
      return [];
    }
  }

  Future<List<Map<String, String>>> getRunningTunnelIds() async {
    _logger.i('## Starting tunnel detection process ##');
    try {
      _logger.i('1. Fetching Windows services...');
      final services = await getRunningWindowsServices();
      _logger.i('2. Found ${services.length} cloudflared-related services');

      final List<Map<String, String>> tunnelInfo = [];
      for (final service in services) {
        _logger.i('3. Processing service: ${service['name']}');
        final path = service['PathName'] ?? '';
        
        if (path.isEmpty) {
          _logger.w('4. Skipping service with empty path');
          continue;
        }

        _logger.i('5. Service path analysis:');
        _logger.d('   Full path: "$path"');
        _logger.d('   Path length: ${path.length} characters');

        _logger.i('6. Token extraction attempt...');
        final tokenMatch = RegExp(r'--token[=\s"'' ]*([^s''"]+)').firstMatch(path);
        
        if (tokenMatch != null) {
          final token = tokenMatch.group(1);
          _logger.i('7. Token found in path');
          _logger.d('   Raw token: ${token?.substring(0, min<int>(20, token.length))}...');
          _logger.d('   Token length: ${token?.length ?? 0} characters');

          try {
            _logger.i('8. Decoding token...');
            final tunnelId = await _extractTunnelIdFromToken(token!);
            
            if (tunnelId != null) {
              _logger.i('9. Successfully decoded tunnel ID: $tunnelId');
              _logger.i('10. Fetching Cloudflare tunnel list...');
              final tunnels = await listTunnels();
              _logger.i('11. Found ${tunnels.length} Cloudflare tunnels');
              
              _logger.d('12. Tunnel IDs from Cloudflare:');
              for (var t in tunnels) {
                _logger.d('   - ${t['id']}');
              }

              final tunnel = tunnels.firstWhere(
                (t) => t['id'].toString().toLowerCase() == tunnelId.toLowerCase(),
                orElse: () => <String, String>{},
              );

              if (tunnel.isNotEmpty) {
                _logger.i('13. Matched tunnel: ${tunnel['name']} (${tunnel['id']})');
                tunnelInfo.add({
                  'id': tunnelId,
                  'name': tunnel['name']?.toString() ?? 'Unnamed Tunnel',
                });
              } else {
                _logger.w('14. No Cloudflare tunnel matches ID: $tunnelId');
                _logger.d('   Available IDs: ${tunnels.map((t) => t['id']).join(', ')}');
              }
            } else {
              _logger.w('9. Failed to decode token');
            }
          } catch (e) {
            _logger.e('15. Token processing failed: $e');
          }
        } else {
          _logger.w('7. No token found in service path');
          _logger.d('   Path snippet: ${path.substring(0, min<int>(100, path.length))}...');
        }
      }
      _logger.i('16. Completed tunnel detection. Found ${tunnelInfo.length} valid tunnels');
      return tunnelInfo;
    } catch (e) {
      _logger.e('!! Tunnel detection process failed !!: $e');
      return [];
    }
  }

  Future<String?> _extractTunnelIdFromToken(String token) async {
    LogService().info('Starting token extraction...');
    LogService().info('Input token (first 10 chars): ${token.substring(0, min(10, token.length))}...');
    
    try {
      final cleanedToken = token.trim().replaceAll('"', '');
      LogService().info('Cleaned token (first 10 chars): ${cleanedToken.substring(0, min(10, cleanedToken.length))}...');
      
      final normalizedToken = base64Url.normalize(cleanedToken);
      LogService().info('Normalized token (first 10 chars): ${normalizedToken.substring(0, min(10, normalizedToken.length))}...');
      
      final decodedBytes = base64Url.decode(normalizedToken);
      final decodedString = utf8.decode(decodedBytes);
      LogService().info('Decoded string: $decodedString');
      
      final jsonPayload = json.decode(decodedString) as Map<String, dynamic>;
      LogService().info('JSON payload: $jsonPayload');
      
      final tunnelId = jsonPayload['t']?.toString();
      LogService().info('Extracted tunnel ID: $tunnelId');
      return tunnelId;
    } catch (e, stack) {
      LogService().error('Token decoding failed: $e');
      LogService().error('Stack trace: $stack');
      return null;
    }
  }

  List<Tunnel> getActiveTunnels() {
    return _activeTunnels.values.toList();
  }

  // Add this new method to check for running cloudflared processes
  Future<Map<String, int>> getRunningCloudflaredProcesses() async {
    try {
      final Map<String, int> runningTunnels = {};
      
      for (final entry in _connectionStates.entries) {
        if (entry.value == 'running') {
          final parts = entry.key.split(':');
          if (parts.length == 2) {
            final domain = parts[0];
            final port = int.tryParse(parts[1]);
            if (port != null) {
              runningTunnels[domain] = port;
            }
          }
        }
      }
      
      return runningTunnels;
    } catch (e) {
      _logger.e('Error getting running cloudflared processes: ${e.toString()}');
      return {};
    }
  }

  // Install cloudflared
  Future<bool> installCloudflared(String token) async {
    try {
      final tempDir = await Directory.systemTemp.createTemp('cloudflared_');
      final installerPath = '${tempDir.path}\\cloudflared-windows-amd64.msi';
      
      // Download the installer
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi')
      );
      final response = await request.close();
      
      final file = File(installerPath);
      await response.pipe(file.openWrite());
      
      // Run the installer
      final installResult = await Process.run('msiexec', ['/i', installerPath, '/quiet', '/qn']);
      
      if (installResult.exitCode != 0) {
        _logger.e('Failed to install cloudflared: ${installResult.stderr}');
        return false;
      }
      
      // Wait for installation to complete
      await Future.delayed(const Duration(seconds: 5));
      
      // Install the service with the provided token
      final serviceResult = await Process.run('cloudflared', [
        'service',
        'install',
        token
      ]);
      
      if (serviceResult.exitCode != 0) {
        _logger.e('Failed to install cloudflared service: ${serviceResult.stderr}');
        return false;
      }
      
      return true;
    } catch (e) {
      _logger.e('Error installing cloudflared: $e');
      return false;
    }
  }

  // Add a new method to handle the login process
  Future<bool> initiateLogin() async {
    try {
      LogService().info('Initiating cloudflared login process...');
      ProcessResult result = await Process.run('cloudflared', ['login'], runInShell: true);
      
      if (result.exitCode == 0) {
        LogService().info('Login process initiated successfully');
        return true;
      } else {
        LogService().error('Failed to initiate login: ${result.stderr}');
        return false;
      }
    } catch (e) {
      LogService().error('Error during login process: $e');
      return false;
    }
  }
}
