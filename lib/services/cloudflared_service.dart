// lib/services/cloudflared_service.dart

import 'dart:io';
import 'dart:convert';
import '../models/tunnel.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'dart:math';
import 'package:process/process.dart';
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

  // Get running tunnel info
  Future<Map<String, String>?> getRunningTunnelInfo() async {
    try {
      final services = await getRunningWindowsServices();
      if (services.isEmpty) {
        _logger.i('No cloudflared services found');
        return null;
      }

      for (final service in services) {
        final path = service['path'] ?? '';
        if (path.isEmpty) continue;

        final tokenMatch = RegExp(r'--token[=\s"'' ]*([^\s''"]+)').firstMatch(path);
        if (tokenMatch == null) continue;

        final token = tokenMatch.group(1);
        final tunnelId = await _extractTunnelIdFromToken(token!);
        
        if (tunnelId != null) {
          final tunnels = await listTunnels();
          final tunnel = tunnels.firstWhere(
            (t) => t['id'].toString().toLowerCase() == tunnelId.toLowerCase(),
            orElse: () => <String, String>{},
          );

          if (tunnel.isNotEmpty) {
            return {
              'id': tunnelId,
              'name': tunnel['name']?.toString() ?? 'Unnamed Tunnel',
            };
          }
        }
      }
      return null;
    } catch (e) {
      _logger.e('Error getting running tunnel info', e);
      return null;
    }
  }

  // Start port forwarding
  Future<bool> startPortForwarding(String domain, String port) async {
    try {
      final portNum = int.parse(port);
      LogService().info('Starting port forwarding process...');
      LogService().info('Domain: $domain, Port: $port');
      
      // Check if port is available
      if (!await checkPortAvailability(portNum)) {
        LogService().error('ERROR: Port $port is already in use');
        return false;
      }
      
      // Check for existing process
      if (_processes.containsKey(portNum)) {
        LogService().warning('Port $port already has a running process');
        return true; // Already running
      }

      // Get cloudflared path
      final cloudflaredPath = await _getCloudflaredPath();
      if (cloudflaredPath == null) {
        LogService().error('ERROR: Could not find cloudflared executable');
        return false;
      }
      LogService().info('Found cloudflared at: $cloudflaredPath');

      // Create and execute the VBS script
      LogService().info('Executing cloudflared command...');
      final vbsPath = await _createVbsScript(cloudflaredPath, domain, port);
      if (vbsPath == null) {
        LogService().error('ERROR: Failed to create VBS script');
        return false;
      }

      // Start the process and wait for it to initialize
      await Process.run('wscript.exe', [vbsPath]);
      
      // Give the process a moment to start
      await Future.delayed(const Duration(milliseconds: 100));

      // More efficient process detection with shorter intervals
      bool processFound = false;
      for (int i = 0; i < 5; i++) {
        final result = await Process.run('powershell', [
          'Get-CimInstance Win32_Process -Filter "Name = \'cloudflared.exe\'" | Select-Object ProcessId,CommandLine | ConvertTo-Json'
        ]);

        try {
          final output = result.stdout.toString().trim();
          if (output.isEmpty) {
            await Future.delayed(const Duration(milliseconds: 200));
            continue;
          }

          dynamic decoded = json.decode(output);
          List<dynamic> processes = decoded is List ? decoded : [decoded];

          for (var process in processes) {
            if (process['CommandLine']?.toString().contains('access $domain') == true) {
              final cloudflaredPid = process['ProcessId'];
              if (cloudflaredPid != null) {
                LogService().info('Found process: PID $cloudflaredPid for $domain');
                _cloudflaredPids[portNum] = cloudflaredPid;
                processFound = true;
                break;
              }
            }
          }
          
          if (processFound) break;
        } catch (e) {
          LogService().error('Error parsing process info: $e');
        }

        if (!processFound) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (!processFound) {
        LogService().warning('Could not find cloudflared process for $domain');
      }

      // Add to active tunnels
      _activeTunnels[domain] = Tunnel(
        domain: domain,
        port: port,
        protocol: 'tcp',
        isRunning: true
      );

      // Quick connection check
      int retries = 0;
      while (retries < 3) {
        if (await _checkTunnelConnection(domain)) {
          LogService().system('Tunnel appears to be running (port is in use)');
          return true;
        }
        retries++;
        if (retries < 3) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      LogService().error('ERROR: Tunnel does not appear to be running (port is still available)');
      await stopPortForwarding(port);
      return false;
    } catch (e) {
      LogService().error('ERROR: Failed to start port forwarding: $e');
      return false;
    }
  }

  Future<String?> _createVbsScript(String cloudflaredPath, String domain, String port) async {
    try {
      final tempDir = await Directory.systemTemp.createTemp('cloudflared_');
      final vbsFile = File('${tempDir.path}\\run_cloudflared.vbs');
      
      // Create VBS script that runs the command completely hidden
      await vbsFile.writeAsString('''
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run """$cloudflaredPath"" access tcp --hostname $domain --url tcp://localhost:$port", 0, False
''');
      
      return vbsFile.path;
    } catch (e) {
      _logger.e('Error creating VBS file: $e');
      return null;
    }
  }

  void _cleanupProcess(int port) {
    final process = _processes[port];
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (e) {
        _logger.e('Error killing process: $e');
      }
      _processes.remove(port);
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
      LogService().info('Starting process termination for port $port');

      // Initial state logging
      final initialPortCheck = await checkPortAvailability(portNum);
      LogService().info('Initial port state - Port $port is ${initialPortCheck ? "available" : "in use"}');
      LogService().info('Current _cloudflaredPids map: $_cloudflaredPids');
      LogService().info('Current _processes map: $_processes');
      LogService().info('Current _activeTunnels map: $_activeTunnels');

      // Get all running cloudflared processes
      final result = await Process.run('powershell', [
        'Get-CimInstance Win32_Process -Filter "Name = \'cloudflared.exe\'" | Select-Object ProcessId,CommandLine | ConvertTo-Json'
      ]);

      if (result.stdout.toString().trim().isNotEmpty) {
        LogService().info('Found running cloudflared processes: ${result.stdout.toString().trim()}');
      } else {
        LogService().info('No running cloudflared processes found via Get-CimInstance');
      }

      // Try to kill the process if we have its PID
      final cloudflaredPid = _cloudflaredPids[portNum];
      if (cloudflaredPid != null) {
        LogService().info('Found stored PID $cloudflaredPid for port $port');

        // Check if the process is still running
        final processCheckResult = await Process.run(
          'powershell',
          ['Get-Process -Id $cloudflaredPid -ErrorAction SilentlyContinue | Select-Object Id | ConvertTo-Json'],
        );

        LogService().info('Process check result: ${processCheckResult.stdout.toString().trim()}');

        // Kill the process
        final killResult = await Process.run(
          'powershell',
          ['Stop-Process -Id $cloudflaredPid -Force -ErrorAction SilentlyContinue'],
        );

        LogService().info('Kill process result: ${killResult.stdout.toString().trim()}');

        if (killResult.exitCode == 0) {
          // More detailed port availability checking
          for (int i = 0; i < 5; i++) {
            await Future.delayed(const Duration(milliseconds: 200));
            final portCheck = await checkPortAvailability(portNum);
            LogService().info('Port availability check ${i + 1}/5: ${portCheck ? "available" : "still in use"}');
            
            if (portCheck) {
              LogService().system('Process successfully terminated and port is available');
              _cloudflaredPids.remove(portNum);
              _processes.remove(portNum);
              _activeTunnels.removeWhere((domain, tunnel) => tunnel.port == port);
              
              // Verify cleanup
              LogService().info('After cleanup - _cloudflaredPids: $_cloudflaredPids');
              LogService().info('After cleanup - _processes: $_processes');
              LogService().info('After cleanup - _activeTunnels: $_activeTunnels');
              return;
            }
          }
          LogService().warning('Port still in use after killing process with PID $cloudflaredPid');
        } else {
          LogService().error('Failed to kill process with PID $cloudflaredPid');
        }
      } else {
        LogService().warning('No stored PID found for port $port');
      }

      // If we're here, either no PID was found or the kill wasn't successful
      LogService().info('Attempting taskkill as fallback');
      final taskkillResult = await Process.run(
        'taskkill',
        ['/F', '/IM', 'cloudflared.exe'],
        runInShell: true
      );
      LogService().info('Taskkill result: ${taskkillResult.stdout.toString().trim()}');
      LogService().info('Taskkill error output: ${taskkillResult.stderr.toString().trim()}');
      
      // Quick final check with more logging
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        final portCheck = await checkPortAvailability(portNum);
        LogService().info('Final port check ${i + 1}/5: ${portCheck ? "available" : "still in use"}');
        
        if (portCheck) {
          LogService().system('Port is now available after taskkill');
          _cloudflaredPids.remove(portNum);
          _processes.remove(portNum);
          _activeTunnels.removeWhere((domain, tunnel) => tunnel.port == port);
          
          // Verify final state
          LogService().info('Final state - _cloudflaredPids: $_cloudflaredPids');
          LogService().info('Final state - _processes: $_processes');
          LogService().info('Final state - _activeTunnels: $_activeTunnels');
          return;
        }
      }
      
      LogService().warning('WARNING: Port $port is still in use after all termination attempts');
      
    } catch (e, stack) {
      _logger.e('Error stopping port forwarding: $e\n$stack');
      LogService().error('Error stopping port forwarding: $e');
      LogService().error('Stack trace: $stack');
    }
  }

  Future<void> startTunnel(Tunnel tunnel) async {
    try {
      await Process.run(
        'cloudflared',
        [
          'tunnel',
          '--url',
          '${tunnel.protocol.toLowerCase()}://localhost:${tunnel.port}',
          tunnel.domain
        ],
        runInShell: true,
      );
    } catch (e) {
      _logger.e('Error starting tunnel: $e');
      rethrow;
    }
  }

  Future<void> stopTunnel(Tunnel tunnel) async {
    try {
      await Process.run(
        'cloudflared',
        ['tunnel', 'delete', '-f', tunnel.domain],
        runInShell: true,
      );
    } catch (e) {
      _logger.e('Error stopping tunnel: $e');
      rethrow;
    }
  }

  bool isTunnelRunning(Tunnel tunnel) {
    if (!tunnel.isLocal) return false;
    // Check if there's a process running for this specific port
    final portNum = int.tryParse(tunnel.port);
    if (portNum == null) return false;
    return _processes.containsKey(portNum);
  }

  Future<bool> _checkPortAvailability(int port) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await server.close();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> isLoggedIn() async {
    try {
      ProcessResult result = await Process.run('cloudflared', ['tunnel', 'list'], runInShell: true);
      return result.exitCode == 0;
    } catch (e) {
      _logger.e('Error checking login status: $e');
      return false;
    }
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
      ProcessResult result = await Process.run('cloudflared', ['tunnel', 'list', '--output', 'json'], runInShell: true);
      if (result.exitCode != 0) {
        _logger.e('Failed to list tunnels: ${result.stderr}');
        return [];
      }

      List<dynamic> tunnels = json.decode(result.stdout.toString());
      return tunnels.map((tunnel) => {
        'id': tunnel['id'] as String,
        'name': tunnel['name'] as String,
        'url': tunnel['url'] as String? ?? '',
      }).toList();
    } catch (e) {
      _logger.e('Error listing tunnels: $e');
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

  Future<String?> _getTunnelIdByDomain(String domain) async {
    try {
      final tunnels = await listTunnels();
      for (var tunnel in tunnels) {
        if (tunnel['url']?.contains(domain) == true) {
          return tunnel['id'];
        }
      }
      return null;
    } catch (e) {
      _logger.e('Error getting tunnel ID: $e');
      return null;
    }
  }

  Future<int> findNextAvailablePort(int startPort) async {
    int port = startPort;
    while (!(await checkPortAvailability(port))) {
      port++;
    }
    return port;
  }

  Future<List<Map<String, String>>> getAvailableTunnels() async {
    try {
      ProcessResult result = await Process.run(
        'cloudflared',
        ['tunnel', 'list', '--output', 'json'],
        runInShell: true,
      );

      if (result.exitCode != 0) {
        _logger.e('Failed to list tunnels: ${result.stderr}');
        return [];
      }

      List<dynamic> tunnels = json.decode(result.stdout.toString());
      return tunnels.map((tunnel) => {
        'id': tunnel['id'] as String,
        'name': tunnel['name'] as String,
        'url': tunnel['url'] as String? ?? '',
      }).toList();
    } catch (e) {
      _logger.e('Error listing tunnels: $e');
      return [];
    }
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
      _logger.i('Executing PowerShell command to get services...');
      final command = [
        '-Command',
        r"Get-CimInstance Win32_Service | Where-Object { $_.PathName -like '*cloudflared*' }"
        r" | Select-Object Name,PathName | ConvertTo-Json -Compress"
      ];
      
      _logger.d('Full command: powershell ${command.join(' ')}');
      
      final result = await Process.run(
        'powershell',
        command,
        runInShell: true,
      );

      _logger.i('Command executed. Exit code: ${result.exitCode}');
      _logger.d('Command stdout: ${result.stdout}');
      _logger.d('Command stderr: ${result.stderr}');

      if (result.exitCode != 0) {
        _logger.e('PowerShell command failed with exit code ${result.exitCode}');
        return [];
      }

      final output = result.stdout.toString().trim();
      _logger.i('Raw service output (${output.length} chars): ${output.substring(0, min<int>(200, output.length))}...');

      if (output.isEmpty) {
        _logger.w('No cloudflared services found in output');
        return [];
      }

      try {
        dynamic decoded = json.decode(output);
        
        // Handle both single service (Object) and multiple services (Array)
        List<dynamic> services = [];
        if (decoded is List) {
          services = decoded;
          _logger.d('Decoded ${services.length} services from JSON array');
        } else if (decoded is Map) {
          services = [decoded];
          _logger.d('Decoded single service from JSON object');
        } else {
          _logger.e('Unexpected JSON type: ${decoded.runtimeType}');
          return [];
        }

        _logger.i('Successfully parsed ${services.length} cloudflared services');
        
        return services.map((s) {
          final path = s['PathName']?.toString().replaceAll('"', '') ?? '';
          final name = s['Name']?.toString() ?? 'Unnamed Service';
          
          _logger.d('Service details:');
          _logger.d('  Name: $name');
          _logger.d('  Path: $path');
          
          return {
            'name': name,
            'path': path,
          };
        }).toList();
      } catch (e) {
        _logger.e('JSON parsing failed for output: $output', e);
        return [];
      }
    } catch (e) {
      _logger.e('Error getting Windows services', e);
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
        final path = service['path'] ?? '';
        
        if (path.isEmpty) {
          _logger.w('4. Skipping service with empty path');
          continue;
        }

        _logger.i('5. Service path analysis:');
        _logger.d('   Full path: "$path"');
        _logger.d('   Path length: ${path.length} characters');

        _logger.i('6. Token extraction attempt...');
        final tokenMatch = RegExp(r'--token[=\s"'' ]*([^\s''"]+)').firstMatch(path);
        
        if (tokenMatch != null) {
          final token = tokenMatch.group(1);
          _logger.i('7. Token found in path');
          _logger.d('   Raw token: ${token?.substring(0, min<int>(20, token?.length ?? 0))}...');
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
              tunnels.forEach((t) => _logger.d('   - ${t['id']}'));

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
            _logger.e('15. Token processing failed', e);
          }
        } else {
          _logger.w('7. No token found in service path');
          _logger.d('   Path snippet: ${path.substring(0, min<int>(100, path.length))}...');
        }
      }
      _logger.i('16. Completed tunnel detection. Found ${tunnelInfo.length} valid tunnels');
      return tunnelInfo;
    } catch (e) {
      _logger.e('!! Tunnel detection process failed !!', e);
      return [];
    }
  }

  Future<String?> _extractTunnelIdFromToken(String token) async {
    _logger.d('Decoding token: ${token.substring(0, min<int>(8, token.length))}...');
    try {
      final cleanedToken = token.trim().replaceAll('"', '');
      final decodedBytes = base64Url.decode(base64Url.normalize(cleanedToken));
      final decodedString = utf8.decode(decodedBytes);
      _logger.v('Decoded token content: $decodedString');
      
      final jsonPayload = json.decode(decodedString) as Map<String, dynamic>;
      final tunnelId = jsonPayload['t']?.toString();
      _logger.d('Extracted tunnel ID from token: $tunnelId');
      return tunnelId;
    } catch (e) {
      _logger.e('Token decoding failed', e);
      return null;
    }
  }

  List<Tunnel> getActiveTunnels() {
    return _activeTunnels.values.toList();
  }

  // Add this new method to check for running cloudflared processes
  Future<Map<String, int>> getRunningCloudflaredProcesses() async {
    try {
      final result = await Process.run(
        'powershell',
        [
          '-Command',
          '''Get-CimInstance Win32_Process | Where-Object { \$_.Name -eq "cloudflared.exe" } | Select-Object ProcessId,CommandLine | ConvertTo-Json'''
        ],
        runInShell: true
      );

      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        final Map<String, int> runningTunnels = {};
        
        try {
          final processes = json.decode(result.stdout.toString().trim());
          final processList = processes is List ? processes : [processes];
          
          for (var process in processList) {
            if (process['CommandLine'] != null) {
              final commandLine = process['CommandLine'].toString();
              final hostnameMatch = RegExp(r'--hostname\s+([^\s]+)').firstMatch(commandLine);
              final portMatch = RegExp(r'localhost:(\d+)').firstMatch(commandLine);
              
              if (hostnameMatch != null && portMatch != null) {
                final domain = hostnameMatch.group(1)!;
                final port = int.parse(portMatch.group(1)!);
                runningTunnels[domain] = port;
              }
            }
          }
        } catch (e) {
          _logger.e('Error parsing process info: $e');
        }
        
        return runningTunnels;
      }
      
      return {};
    } catch (e) {
      _logger.e('Error getting running cloudflared processes: $e');
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
}
