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
      LogService().addLog('Starting port forwarding process...');
      LogService().addLog('Domain: $domain, Port: $port');
      
      // Check if port is available
      if (!await checkPortAvailability(portNum)) {
        LogService().addLog('ERROR: Port $port is already in use');
        return false;
      }
      
      // Check for existing process
      if (_processes.containsKey(portNum)) {
        LogService().addLog('Port $port already has a running process');
        return true; // Already running
      }

      // Get cloudflared path
      final cloudflaredPath = await _getCloudflaredPath();
      if (cloudflaredPath == null) {
        LogService().addLog('ERROR: Could not find cloudflared executable');
        _logger.e('Could not find cloudflared executable');
        return false;
      }
      LogService().addLog('Found cloudflared at: $cloudflaredPath');

      _logger.i('Starting cloudflared on port $port for domain $domain');
      LogService().addLog('Executing cloudflared command...');
      
      // Create a VBS script to hide the window completely
      final vbsFile = await _createVbsFile(cloudflaredPath, domain, port);
      if (vbsFile == null) {
        LogService().addLog('ERROR: Failed to create VBS script');
        return false;
      }

      // Start the process with the VBS script
      final process = await Process.start(
        'wscript.exe',
        [vbsFile.path],
        mode: ProcessStartMode.detached,
      );

      // Wait longer for the cloudflared process to start and stabilize
      await Future.delayed(const Duration(seconds: 5));
      
      // Find the actual cloudflared process using a more reliable method
      final result = await Process.run(
        'powershell',
        [
          '-Command',
          r'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "cloudflared.exe" } | Select-Object ProcessId,CommandLine | ConvertTo-Json'
        ],
        runInShell: true
      );
      
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        LogService().addLog('Found processes: ${result.stdout.toString().trim()}');
        try {
          final processes = json.decode(result.stdout.toString().trim());
          final matchingProcess = processes is List ? 
            processes.firstWhere(
              (p) => p['CommandLine'] != null && 
                     p['CommandLine'].toString().contains(domain) && 
                     p['CommandLine'].toString().contains(port),
              orElse: () => null
            ) : 
            (processes['CommandLine'] != null && 
             processes['CommandLine'].toString().contains(domain) && 
             processes['CommandLine'].toString().contains(port) ? 
             processes : null);

          if (matchingProcess != null) {
            final cloudflaredPid = matchingProcess['ProcessId'];
            if (cloudflaredPid != null) {
              LogService().addLog('Cloudflared process started with PID: $cloudflaredPid');
              _cloudflaredPids[portNum] = cloudflaredPid;
            }
          } else {
            LogService().addLog('WARNING: Could not find matching process, will retry in 2 seconds');
            // Retry once after a delay
            await Future.delayed(const Duration(seconds: 2));
            final retryResult = await Process.run(
              'powershell',
              [
                '-Command',
                r'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "cloudflared.exe" } | Select-Object ProcessId,CommandLine | ConvertTo-Json'
              ],
              runInShell: true
            );
            
            if (retryResult.exitCode == 0 && retryResult.stdout.toString().trim().isNotEmpty) {
              LogService().addLog('Retry found processes: ${retryResult.stdout.toString().trim()}');
              final retryProcesses = json.decode(retryResult.stdout.toString().trim());
              final retryMatch = retryProcesses is List ? 
                retryProcesses.firstWhere(
                  (p) => p['CommandLine'] != null && 
                         p['CommandLine'].toString().contains(domain) && 
                         p['CommandLine'].toString().contains(port),
                  orElse: () => null
                ) : 
                (retryProcesses['CommandLine'] != null && 
                 retryProcesses['CommandLine'].toString().contains(domain) && 
                 retryProcesses['CommandLine'].toString().contains(port) ? 
                 retryProcesses : null);

              if (retryMatch != null) {
                final cloudflaredPid = retryMatch['ProcessId'];
                if (cloudflaredPid != null) {
                  LogService().addLog('Cloudflared process found on retry with PID: $cloudflaredPid');
                  _cloudflaredPids[portNum] = cloudflaredPid;
                }
              } else {
                LogService().addLog('WARNING: Could not find cloudflared process even after retry');
              }
            }
          }
        } catch (e) {
          LogService().addLog('Error parsing process info: $e');
        }
      }

      // Add to active tunnels
      _activeTunnels[domain] = Tunnel(
        domain: domain,
        port: port,
        protocol: 'tcp',
        isRunning: true
      );

      // Wait a bit to ensure the process started
      await Future.delayed(const Duration(seconds: 2));
      
      // Check if the port is now in use (indicating the tunnel is running)
      if (!await checkPortAvailability(portNum)) {
        LogService().addLog('Tunnel appears to be running (port is in use)');
        return true;
      } else {
        LogService().addLog('ERROR: Tunnel does not appear to be running (port is still available)');
        await stopPortForwarding(port);
        return false;
      }

    } catch (e, stack) {
      LogService().addLog('ERROR: Failed to start port forwarding: $e');
      _logger.e('Failed to start port forwarding', e, stack);
      return false;
    }
  }

  Future<File?> _createVbsFile(String cloudflaredPath, String domain, String port) async {
    try {
      final tempDir = await Directory.systemTemp.createTemp('cloudflared_');
      final vbsFile = File('${tempDir.path}\\run_cloudflared.vbs');
      
      // Create VBS script that runs the command completely hidden
      await vbsFile.writeAsString('''
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run """$cloudflaredPath"" access tcp --hostname $domain --url tcp://localhost:$port", 0, False
''');
      
      return vbsFile;
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
      LogService().addLog('Starting process termination for port $port');
      
      // Log initial state
      final initialPortCheck = await checkPortAvailability(portNum);
      LogService().addLog('Initial port state - Port $port is ${initialPortCheck ? "available" : "in use"}');
      
      // First try to find all running cloudflared processes
      final initialProcessList = await Process.run(
        'powershell',
        [
          '-Command',
          r'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "cloudflared.exe" } | Select-Object ProcessId,CommandLine | ConvertTo-Json'
        ],
        runInShell: true
      );
      
      LogService().addLog('Initial cloudflared processes: ${initialProcessList.stdout.toString().trim()}');
      
      // First try to find the process if we don't have the PID
      if (!_cloudflaredPids.containsKey(portNum)) {
        LogService().addLog('No cached PID found, searching for process with port $port');
        final findResult = await Process.run(
          'powershell',
          [
            '-Command',
            '''Get-CimInstance Win32_Process | Where-Object { \$_.Name -eq "cloudflared.exe" -and \$_.CommandLine -like "*${port}*" } | Select-Object -ExpandProperty ProcessId'''
          ],
          runInShell: true
        );
        
        LogService().addLog('Process search result: ${findResult.stdout.toString().trim()}');
        
        if (findResult.exitCode == 0 && findResult.stdout.toString().trim().isNotEmpty) {
          final foundPid = int.tryParse(findResult.stdout.toString().trim());
          if (foundPid != null) {
            LogService().addLog('Found process with PID: $foundPid');
            _cloudflaredPids[portNum] = foundPid;
          }
        } else {
          LogService().addLog('No specific process found for port $port (Exit code: ${findResult.exitCode})');
        }
      }

      final cloudflaredPid = _cloudflaredPids[portNum];
      if (cloudflaredPid != null) {
        LogService().addLog('Attempting to kill cloudflared process with PID: $cloudflaredPid');
        
        // Try to kill the specific process first
        final killResult = await Process.run(
          'powershell',
          [
            '-Command',
            'Stop-Process -Id ${cloudflaredPid} -Force -ErrorAction SilentlyContinue; \$?'
          ],
          runInShell: true
        );

        LogService().addLog('Kill result exit code: ${killResult.exitCode}');
        LogService().addLog('Kill result output: ${killResult.stdout.toString().trim()}');
        LogService().addLog('Kill result error: ${killResult.stderr.toString().trim()}');

        // If the specific kill failed, try to kill all matching processes
        if (killResult.exitCode != 0) {
          LogService().addLog('Failed to kill specific process, trying to kill all matching processes');
          final killAllResult = await Process.run(
            'powershell',
            [
              '-Command',
              '''Get-CimInstance Win32_Process | Where-Object { \$_.Name -eq "cloudflared.exe" -and \$_.CommandLine -like "*${port}*" } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force; Write-Output "Killed process: \$(\$_.ProcessId)" }'''
            ],
            runInShell: true
          );
          
          LogService().addLog('Kill all result exit code: ${killAllResult.exitCode}');
          LogService().addLog('Kill all result output: ${killAllResult.stdout.toString().trim()}');
          LogService().addLog('Kill all result error: ${killAllResult.stderr.toString().trim()}');
        }
        
        _cloudflaredPids.remove(portNum);
        _processes.remove(portNum);
      } else {
        LogService().addLog('No PID found for port $port, attempting to kill all matching processes');
        // Try to kill all matching processes as a fallback
        final result = await Process.run(
          'powershell',
          [
            '-Command',
            '''Get-CimInstance Win32_Process | Where-Object { \$_.Name -eq "cloudflared.exe" -and \$_.CommandLine -like "*${port}*" } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force; Write-Output "Killed process: \$(\$_.ProcessId)" }'''
          ],
          runInShell: true
        );
        
        LogService().addLog('Kill all result exit code: ${result.exitCode}');
        LogService().addLog('Kill all result output: ${result.stdout.toString().trim()}');
        LogService().addLog('Kill all result error: ${result.stderr.toString().trim()}');
      }
      
      // Remove from active tunnels
      _activeTunnels.removeWhere((domain, tunnel) => tunnel.port == port);
      
      // Verify the port is now available
      await Future.delayed(const Duration(seconds: 2));
      final portAvailable = await checkPortAvailability(portNum);
      LogService().addLog('Port availability check after kill - Port $port is ${portAvailable ? "available" : "still in use"}');
      
      // Double check if any cloudflared processes are still running
      final finalProcessList = await Process.run(
        'powershell',
        [
          '-Command',
          r'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "cloudflared.exe" } | Select-Object ProcessId,CommandLine | ConvertTo-Json'
        ],
        runInShell: true
      );
      
      LogService().addLog('Remaining cloudflared processes: ${finalProcessList.stdout.toString().trim()}');
      
      if (!portAvailable) {
        LogService().addLog('WARNING: Port $port is still in use after process termination attempts');
        // Try one last time with taskkill
        final taskkillResult = await Process.run(
          'powershell',
          [
            '-Command',
            'taskkill /F /IM cloudflared.exe; Write-Output "Taskkill executed"'
          ],
          runInShell: true
        );
        LogService().addLog('Taskkill result: ${taskkillResult.stdout.toString().trim()}');
        
        // Final port check
        await Future.delayed(const Duration(seconds: 2));
        final finalPortCheck = await checkPortAvailability(portNum);
        LogService().addLog('Final port state after taskkill - Port $port is ${finalPortCheck ? "available" : "still in use"}');
      }
      
    } catch (e, stack) {
      _logger.e('Error stopping port forwarding: $e\n$stack');
      LogService().addLog('Error stopping port forwarding: $e');
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
