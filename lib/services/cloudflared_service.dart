// lib/services/cloudflared_service.dart

import 'dart:io';
import 'dart:convert';
import '../models/tunnel.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;

class CloudflaredService {
  final Logger _logger = Logger();
  static final CloudflaredService _instance = CloudflaredService._internal();
  factory CloudflaredService() => _instance;

  CloudflaredService._internal();

  final Map<int, Process> _processes = {};

  Future<void> startTunnel(Tunnel tunnel) async {
    if (!tunnel.isLocal) {
      _logger.e('Cannot start a remote tunnel');
      return;
    }

    if (_processes.containsKey(tunnel.id)) {
      _logger.w('Tunnel ${tunnel.id} is already running.');
      return;
    }

    try {
      // Check if the port is available before starting
      bool isPortAvailable = await _checkPortAvailability(int.parse(tunnel.port));
      if (!isPortAvailable) {
        _logger.e('Port ${tunnel.port} is already in use.');
        return;
      }

      // First, run the tunnel service
      final tunnelId = await _getTunnelIdByDomain(tunnel.domain);
      if (tunnelId == null) {
        _logger.e('Could not find tunnel ID for domain: ${tunnel.domain}');
        return;
      }

      // Start the tunnel process
      Process tunnelProcess = await Process.start('cloudflared', [
        'tunnel',
        '--config',
        p.join((await _getConfigDir()).path, '$tunnelId.yml'),
        'run',
      ], runInShell: true);

      // Wait a bit for the tunnel to start
      await Future.delayed(const Duration(seconds: 2));

      // Then start the TCP tunnel
      Process process = await Process.start('cloudflared', [
        'access',
        'tcp',
        '--hostname=${tunnel.domain}',
        '--url=tcp://localhost:${tunnel.port}',
      ]);

      process.stdout.transform(utf8.decoder).listen((data) {
        _logger.i('Cloudflared [${tunnel.domain}]: $data');
      });

      process.stderr.transform(utf8.decoder).listen((data) {
        _logger.e('Cloudflared [${tunnel.domain} Error]: $data');
      });

      tunnelProcess.stdout.transform(utf8.decoder).listen((data) {
        _logger.i('Tunnel [${tunnel.domain}]: $data');
      });

      tunnelProcess.stderr.transform(utf8.decoder).listen((data) {
        _logger.e('Tunnel [${tunnel.domain} Error]: $data');
      });

      _processes[tunnel.id!] = process;
      _logger.i('Started tunnel ${tunnel.domain} on port ${tunnel.port}.');
    } catch (e) {
      _logger.e('Failed to start tunnel ${tunnel.domain}: $e');
    }
  }

  Future<void> stopTunnel(Tunnel tunnel) async {
    if (!tunnel.isLocal) {
      _logger.e('Cannot stop a remote tunnel');
      return;
    }

    final process = _processes[tunnel.id!];
    if (process != null) {
      process.kill();
      _processes.remove(tunnel.id!);
      _logger.i('Stopped tunnel ${tunnel.domain}.');
    } else {
      _logger.w('No running tunnel found for ${tunnel.domain}.');
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
      return {'success': false, 'error': e.toString()};
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
}
