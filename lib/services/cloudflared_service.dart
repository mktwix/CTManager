// lib/services/cloudflared_service.dart

import 'dart:io';
import 'dart:convert';
import '../models/tunnel.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'dart:math';
import 'package:process/process.dart';

class CloudflaredService {
  final Logger _logger = Logger();
  static final CloudflaredService _instance = CloudflaredService._internal();
  factory CloudflaredService() => _instance;

  CloudflaredService._internal();

  final Map<int, Process> _processes = {};
  final Map<String, Tunnel> _activeTunnels = {};

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
      
      // Check for existing process
      if (_processes.containsKey(portNum)) {
        _logger.w('Port $port already has a running process');
        return true; // Already running
      }

      // Check port availability
      if (!await _checkPortAvailability(portNum)) {
        _logger.e('Port $port is already in use');
        return false;
      }

      // Start the TCP tunnel with proper path
      Process process = await Process.start(
        r'C:\Program Files (x86)\cloudflared\cloudflared.exe',
        [
          'access', 
          'tcp',
          '--hostname=$domain',
          '--url=tcp://localhost:$port',
        ],
        runInShell: true,
      );

      process.stdout.transform(utf8.decoder).listen((data) {
        _logger.i('Cloudflared [$domain]: $data');
      });

      process.stderr.transform(utf8.decoder).listen((data) {
        if (data.contains('INF')) {
          _logger.i('Cloudflared [$domain] Info: $data');
        } else if (data.contains('ERR')) {
          _logger.e('Cloudflared [$domain] Error: $data');
          _processes.remove(portNum); // Remove from active processes on error
        } else {
          _logger.w('Cloudflared [$domain] Warning: $data');
        }
      });

      // Add to process map and setup exit handler
      _processes[portNum] = process;
      process.exitCode.then((code) {
        _processes.remove(portNum);
        _logger.i('Cloudflared process for port $port exited with code $code');
      });

      // Add to active tunnels
      _activeTunnels[port] = Tunnel(
        domain: domain,
        port: port,
        protocol: 'tcp',
        isLocal: true,
      );

      _logger.i('Started forwarding for $domain on port $port');
      return true;
    } catch (e) {
      _logger.e('Failed to start port forwarding: $e');
      return false;
    }
  }

  // Stop port forwarding
  Future<void> stopPortForwarding(String port) async {
    final process = _processes[int.parse(port)];
    if (process != null) {
      process.kill();
      _processes.remove(int.parse(port));
      _logger.i('Stopped forwarding on port $port');
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
    // Check both specific process and general running state
    return _processes.isNotEmpty;
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
      // Try to make a connection to the tunnel
      final uri = Uri.parse('https://$domain');
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      await response.drain(); // Dispose of the response
      client.close();
      
      // Any response means the tunnel is running
      return true;
    } catch (e) {
      _logger.e('Error checking tunnel connection: $e');
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
}
