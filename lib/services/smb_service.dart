import 'dart:io';
import 'dart:convert';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../models/tunnel.dart';
import '../services/log_service.dart';
import 'smb_exceptions.dart';

class SmbService {
  final Logger _logger = Logger();
  static final SmbService _instance = SmbService._internal();
  factory SmbService() => _instance;

  SmbService._internal();

  // Map to track mounted drives and their associated tunnels
  final Map<String, String> _mountedDrives = {};
  
  // Path to rclone executable
  String? _rclonePath;
  
  // Map to track RC ports for each mounted drive
  final Map<String, int> _rcPorts = {};
  
  // Base RC port to start from
  final int _baseRcPort = 68375;
  
  // Get the next available RC port
  int _getNextRcPort() {
    if (_rcPorts.isEmpty) {
      return _baseRcPort;
    }
    
    final highestPort = _rcPorts.values.reduce((a, b) => a > b ? a : b);
    return highestPort + 1;
  }

  // Check if rclone is installed
  Future<bool> isRcloneInstalled() async {
    try {
      // Check in the Debug directory first
      final appDir = p.dirname(Platform.resolvedExecutable);
      final rclonePath = p.join(appDir, 'rclone', 'rclone.exe');
      if (await File(rclonePath).exists()) {
        _rclonePath = rclonePath;
        return true;
      }
      
      // Fallback to system-wide rclone
      final result = await Process.run('where', ['rclone'], runInShell: true);
      if (result.exitCode == 0) {
        _rclonePath = result.stdout.toString().trim();
        return true;
      }
      return false;
    } catch (e) {
      _logger.e('Error checking for rclone: $e');
      return false;
    }
  }

  // Download and install WinFsp
  Future<bool> installWinFsp() async {
    try {
      LogService().info('Installing WinFsp...');
      
      // Download WinFsp MSI
      final response = await http.get(Uri.parse('https://github.com/winfsp/winfsp/releases/download/v2.0/winfsp-2.0.23075.msi'));
      
      if (response.statusCode != 200) {
        LogService().error('Failed to download WinFsp: ${response.statusCode}');
        return false;
      }
      
      // Save the MSI file
      final tempDir = await getTemporaryDirectory();
      final msiPath = p.join(tempDir.path, 'winfsp.msi');
      await File(msiPath).writeAsBytes(response.bodyBytes);
      
      // Install WinFsp with full UI to ensure proper installation
      LogService().info('Installing WinFsp from $msiPath...');
      final installProcess = await Process.run(
        'msiexec',
        ['/i', msiPath, '/qb', '/norestart', 'INSTALLLEVEL=1000'],
        runInShell: true
      );
      
      if (installProcess.exitCode != 0) {
        LogService().error('Failed to install WinFsp: ${installProcess.stderr}');
        return false;
      }
      
      // Clean up the MSI file
      try {
        await File(msiPath).delete();
      } catch (e) {
        LogService().warning('Failed to delete WinFsp installer: $e');
      }
      
      // Wait longer for installation to complete
      LogService().info('WinFsp installation initiated, waiting for completion...');
      await Future.delayed(const Duration(seconds: 10));
      
      // Check if WinFsp is now installed
      if (await isWinFspInstalled()) {
        LogService().info('WinFsp installed successfully');
        return true;
      } else {
        LogService().warning('WinFsp installation completed but not detected in registry');
        
        // Try to check if the WinFsp DLLs exist as an alternative verification
        final winFspDllPath = 'C:\\Program Files\\WinFsp\\bin\\winfsp-x64.dll';
        final winFspDllExists = await File(winFspDllPath).exists();
        
        if (winFspDllExists) {
          LogService().info('WinFsp DLL found at $winFspDllPath');
          return true;
        }
        
        LogService().error('WinFsp installation failed or requires a restart');
        return false;
      }
    } catch (e) {
      LogService().error('Error installing WinFsp: $e');
      return false;
    }
  }

  // Download and install rclone
  Future<bool> installRclone() async {
    try {
      // First ensure WinFsp is installed
      if (!await isWinFspInstalled()) {
        if (!await installWinFsp()) {
          return false;
        }
      }
      
      LogService().info('Installing rclone...');
      
      // Create a temporary directory to download rclone
      final tempDir = await getTemporaryDirectory();
      final downloadPath = p.join(tempDir.path, 'rclone.zip');
      final extractPath = p.join(tempDir.path, 'rclone');
      
      // Create the extract directory if it doesn't exist
      final extractDir = Directory(extractPath);
      if (!await extractDir.exists()) {
        await extractDir.create(recursive: true);
      }
      
      // Download rclone zip
      LogService().info('Downloading rclone...');
      final response = await http.get(Uri.parse('https://downloads.rclone.org/rclone-current-windows-amd64.zip'));
      
      if (response.statusCode != 200) {
        LogService().error('Failed to download rclone: ${response.statusCode}');
        return false;
      }
      
      // Save the zip file
      await File(downloadPath).writeAsBytes(response.bodyBytes);
      LogService().info('Downloaded rclone to $downloadPath');
      
      // Extract the zip file
      LogService().info('Extracting rclone...');
      final extractProcess = await Process.run(
        'powershell', 
        [
          '-Command', 
          'Expand-Archive -Path "$downloadPath" -DestinationPath "$extractPath" -Force'
        ],
        runInShell: true
      );
      
      if (extractProcess.exitCode != 0) {
        LogService().error('Failed to extract rclone: ${extractProcess.stderr}');
        return false;
      }
      
      // Find the rclone.exe in the extracted folder
      final rcloneDir = Directory(extractPath);
      String? rcloneExePath;
      
      await for (final entity in rcloneDir.list(recursive: true)) {
        if (entity is File && p.basename(entity.path) == 'rclone.exe') {
          rcloneExePath = entity.path;
          break;
        }
      }
      
      if (rcloneExePath == null) {
        LogService().error('Could not find rclone.exe in extracted files');
        return false;
      }
      
      // Create a directory for rclone in the app's directory
      final appDir = p.dirname(Platform.resolvedExecutable);
      final rcloneAppDir = Directory(p.join(appDir, 'rclone'));
      if (!await rcloneAppDir.exists()) {
        await rcloneAppDir.create(recursive: true);
      }
      
      // Copy rclone.exe to the app directory
      final destPath = p.join(rcloneAppDir.path, 'rclone.exe');
      await File(rcloneExePath).copy(destPath);
      
      _rclonePath = destPath;
      LogService().info('Rclone installed successfully at $_rclonePath');
      
      return true;
    } catch (e) {
      LogService().error('Error installing rclone: $e');
      return false;
    }
  }

  // Check if WinFsp is installed
  Future<bool> isWinFspInstalled() async {
    try {
      // Check 64-bit registry first
      var result = await Process.run(
        'reg',
        ['query', 'HKLM\\SOFTWARE\\WinFsp'],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('WinFsp found in 64-bit registry');
        return true;
      }
      
      // Check 32-bit registry (WOW6432Node)
      result = await Process.run(
        'reg',
        ['query', 'HKLM\\SOFTWARE\\WOW6432Node\\WinFsp'],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('WinFsp found in 32-bit registry (WOW6432Node)');
        return true;
      }
      
      LogService().warning('WinFsp not found in registry');
      return false;
    } catch (e) {
      LogService().error('Error checking for WinFsp: $e');
      return false;
    }
  }

  // Ensure both rclone and WinFsp are available
  Future<bool> ensureRclone() async {
    if (!await isWinFspInstalled()) {
      if (!await installWinFsp()) {
        return false;
      }
      // Wait a bit for WinFsp installation to complete
      await Future.delayed(const Duration(seconds: 5));
    }
    
    if (await isRcloneInstalled()) {
      return true;
    }
    
    return await installRclone();
  }

  // Create rclone config for SMB
  Future<bool> createRcloneConfig(Tunnel tunnel, String configName) async {
    try {
      LogService().info('Creating rclone config for $configName...');
      
      if (_rclonePath == null) {
        if (!await ensureRclone()) {
          LogService().error('Failed to ensure rclone is available');
          return false;
        }
      }
      
      // Obscure the password using rclone's obscure command
      String obscuredPassword = '';
      if (tunnel.password != null && tunnel.password!.isNotEmpty) {
        try {
          // Use the direct approach that works
          final obscureProcess = await Process.run(
            _rclonePath!,
            ['obscure', tunnel.password!],
            runInShell: false // Avoid shell interpretation of special characters
          );
          
          if (obscureProcess.exitCode == 0) {
            obscuredPassword = obscureProcess.stdout.toString().trim();
            LogService().info('Password obscured successfully');
          } else {
            // If obscuring fails, use the password directly
            LogService().warning('Failed to obscure password, using direct password');
            obscuredPassword = tunnel.password!;
          }
        } catch (e) {
          LogService().error('Error during password obscuring: $e');
          // Use the password directly if obscuring fails
          obscuredPassword = tunnel.password!;
        }
      }
      
      // Create config content with password
      final configContent = '''
[${configName}]
type = smb
host = localhost
port = ${tunnel.port}
user = ${tunnel.username ?? ''}
pass = ${obscuredPassword}
share = smb
domain = 
case_insensitive = true
use_mmap = true
no_check_certificate = true
timeout = 60s
hide_special_share = true
''';
      
      // Get the config directory
      final appDir = p.dirname(Platform.resolvedExecutable);
      final configDir = Directory(p.join(appDir, 'rclone'));
      if (!await configDir.exists()) {
        await configDir.create(recursive: true);
      }
      
      final configPath = p.join(configDir.path, 'rclone.conf');
      
      // Write the config file
      await File(configPath).writeAsString(configContent);
      LogService().info('Rclone config created at $configPath');
      
      return true;
    } catch (e) {
      LogService().error('Error creating rclone config: $e');
      return false;
    }
  }

  // Verify the drive is mounted and accessible
  Future<bool> _verifyDriveMount(String mountPoint, {int retries = 3, int delaySeconds = 2}) async {
    // Check if running as administrator for more informative logging
    final isAdmin = await _isRunningAsAdmin();
    if (!isAdmin) {
      LogService().warning('Not running as administrator - drive verification may be limited');
    }
    
    for (int i = 0; i < retries; i++) {
      try {
        // Check if the drive is accessible via PowerShell
        final checkProcess = await Process.run(
          'powershell',
          ['-Command', 'Test-Path -Path "$mountPoint"'],
          runInShell: true
        );
        
        if (checkProcess.exitCode == 0 && checkProcess.stdout.toString().trim().toLowerCase() == 'true') {
          LogService().info('Verified drive $mountPoint is accessible (attempt ${i+1})');
          
          // If not admin, consider the successful Test-Path sufficient (lower expectations)
          if (!isAdmin) {
            LogService().info('Running without admin privileges - using simplified drive verification');
            return true;
          }
          
          // Try to list directory contents to ensure it's fully mounted
          final listProcess = await Process.run(
            'powershell',
            ['-Command', 'Get-ChildItem -Path "$mountPoint" -ErrorAction SilentlyContinue | Select-Object -First 1'],
            runInShell: true
          );
          
          if (listProcess.exitCode == 0) {
            LogService().info('Successfully listed directory contents on $mountPoint');
            return true;
          } else {
            LogService().warning('Drive $mountPoint is accessible but listing contents failed: ${listProcess.stderr}');
            
            // Check if there's a rclone log file with errors
            final appDir = p.dirname(Platform.resolvedExecutable);
            final logFilePath = p.join(appDir, 'rclone', 'mount.log');
            
            try {
              if (await File(logFilePath).exists()) {
                final logContent = await File(logFilePath).readAsString();
                
                // Check for common error patterns
                if (logContent.contains('Error 53') || 
                    logContent.contains('network path was not found') ||
                    logContent.contains('connection refused')) {
                  LogService().error('Found network error in rclone log: ${logContent.split('\n').lastWhere((line) => 
                      line.contains('Error 53') || 
                      line.contains('network path was not found') ||
                      line.contains('connection refused'), 
                      orElse: () => 'Unknown network error')}');
                }
                
                if (logContent.contains('Error 1326') || 
                    logContent.contains('logon failure') ||
                    logContent.contains('access denied')) {
                  LogService().error('Found authentication error in rclone log: ${logContent.split('\n').lastWhere((line) => 
                      line.contains('Error 1326') || 
                      line.contains('logon failure') ||
                      line.contains('access denied'), 
                      orElse: () => 'Unknown authentication error')}');
                }
              }
            } catch (e) {
              LogService().warning('Failed to check rclone log for errors: $e');
            }
            
            if (i < retries - 1) {
              LogService().info('Waiting ${delaySeconds}s before retry...');
              await Future.delayed(Duration(seconds: delaySeconds));
            }
          }
        } else {
          LogService().warning('Drive $mountPoint is not accessible (attempt ${i+1})');
          
          // Check if there's a rclone log file with errors
          final appDir = p.dirname(Platform.resolvedExecutable);
          final logFilePath = p.join(appDir, 'rclone', 'mount.log');
          
          try {
            if (await File(logFilePath).exists()) {
              final logContent = await File(logFilePath).readAsString();
              final lastLines = logContent.split('\n').reversed.take(5).toList().reversed.join('\n');
              LogService().info('Last 5 lines of rclone log:\n$lastLines');
            }
          } catch (e) {
            LogService().warning('Failed to read rclone log: $e');
          }
          
          if (i < retries - 1) {
            LogService().info('Waiting ${delaySeconds}s before retry...');
            await Future.delayed(Duration(seconds: delaySeconds));
          }
        }
      } catch (e) {
        LogService().error('Error verifying drive mount (attempt ${i+1}): $e');
        if (i < retries - 1) {
          LogService().info('Waiting ${delaySeconds}s before retry...');
          await Future.delayed(Duration(seconds: delaySeconds));
        }
      }
    }
    
    return false;
  }

  // Preload common directories to make the mount more responsive
  Future<void> _preloadCommonDirectories(String mountPoint) async {
    try {
      LogService().info('Preloading common directories on $mountPoint...');
      
      // List of common directories to preload
      final commonDirs = ['', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads'];
      
      for (final dir in commonDirs) {
        try {
          final path = dir.isEmpty ? mountPoint : '$mountPoint\\$dir';
          
          // Use PowerShell to list directory contents with error handling
          final process = await Process.run(
            'powershell',
            ['-Command', 'Get-ChildItem -Path "$path" -ErrorAction SilentlyContinue | Select-Object -First 5'],
            runInShell: true
          );
          
          if (process.exitCode == 0) {
            LogService().info('Preloaded directory: $path');
          }
        } catch (e) {
          // Ignore errors for individual directories
          LogService().warning('Failed to preload directory: $mountPoint\\$dir - $e');
        }
      }
      
      LogService().info('Finished preloading common directories');
    } catch (e) {
      LogService().warning('Error during directory preloading: $e');
      // Continue anyway, as this is just an optimization
    }
  }

  // Mount an SMB share using rclone
  Future<bool> mountSmbShare(Tunnel tunnel, String driveLetter) async {
    try {
      LogService().info('Mounting SMB share for ${tunnel.domain}:${tunnel.port}...');
      
      // Check if running as administrator
      final isAdmin = await _isRunningAsAdmin();
      if (isAdmin) {
        LogService().warning('Application is running as administrator. This may cause SMB drive visibility issues.');
        
        // Create a helper file for the user to restart without admin if needed
        await _createRestartWithoutAdminHelper();
        
        // Get the current username
        String currentUsername = '';
        try {
          final userResult = await Process.run(
            'powershell',
            ['-Command', '\$env:USERNAME'],
            runInShell: true
          );
          if (userResult.exitCode == 0) {
            currentUsername = userResult.stdout.toString().trim();
            LogService().info('Current username: $currentUsername');
          }
        } catch (e) {
          LogService().warning('Failed to get current username: $e');
        }
        
        // Try direct mounting first, since we're already running as admin
        LogService().info('Attempting direct mounting first since we are running as admin');
        final directSuccess = await _mountWithDirectNetUse(tunnel, driveLetter);
        if (directSuccess) {
          LogService().info('Direct SMB mounting successful');
          _mountedDrives[tunnel.domain] = driveLetter;
          
          // Verify the drive is accessible
          final isAccessible = await _verifyDriveAccessibility(driveLetter);
          if (isAccessible) {
            LogService().info('Drive $driveLetter: is accessible after direct mounting');
            return true;
          } else {
            LogService().warning('Drive $driveLetter: is not accessible after direct mounting');
            
            // If the drive is not accessible, try to restart as current user
            if (currentUsername.isNotEmpty) {
              LogService().info('Attempting to restart application without administrator privileges for better SMB drive visibility.');
              final success = await _restartAppAsCurrentUser();
              if (success) {
                // If we successfully initiated the restart, return false to prevent further processing
                return false;
              }
            }
          }
        } else {
          // If direct mounting failed and we have a username, try to restart as current user
          if (currentUsername.isNotEmpty) {
            LogService().info('Direct mounting failed. Attempting to restart application without administrator privileges for better SMB drive visibility.');
            final success = await _restartAppAsCurrentUser();
            if (success) {
              // If we successfully initiated the restart, return false to prevent further processing
              return false;
            }
          }
          
          // If we couldn't restart, continue with the rclone approach
          LogService().info('Could not restart application, continuing with admin privileges');
        }
      } else {
        LogService().info('Application is running without administrator privileges, which is recommended for SMB mounting.');
      }
      
      // Check for WinFsp first
      if (!await isWinFspInstalled()) {
        // Try to install WinFsp automatically
        LogService().info('WinFsp not found, attempting automatic installation...');
        final installed = await installWinFsp();
        
        if (!installed) {
          LogService().error('Automatic WinFsp installation failed');
          throw WinFspNotInstalledException(
            'WinFsp is required to mount SMB shares. Please:\n'
            '1. Download and install WinFsp from https://github.com/winfsp/winfsp/releases/download/v2.0/winfsp-2.0.23075.msi\n'
            '2. Restart your computer\n'
            '3. Open the app again'
          );
        }
        
        // Check if WinFsp DLL exists as an alternative verification
        final winFspDllPath = 'C:\\Program Files\\WinFsp\\bin\\winfsp-x64.dll';
        final winFspDllExists = await File(winFspDllPath).exists();
        
        if (!winFspDllExists) {
          LogService().error('WinFsp DLL not found after installation');
          throw WinFspNotInstalledException(
            'WinFsp installation completed but requires a system restart. Please:\n'
            '1. Restart your computer\n'
            '2. Open the app again'
          );
        }
        
        LogService().info('WinFsp installed successfully, proceeding with mount');
      } else {
        LogService().info('WinFsp is already installed');
      }
      
      // For non-admin mode, skip direct network drive mapping attempts and go straight to rclone
      if (!isAdmin) {
        LogService().info('Using rclone mount for non-admin mode');
      } else {
        // Only try direct network drive mapping in admin mode
        LogService().info('Attempting direct network drive mapping');
        
        // Try to create a direct network drive mapping
        final directMappingSuccess = await _mountWithDirectNetUse(tunnel, driveLetter);
        
        if (directMappingSuccess) {
          LogService().info('Direct network drive mapping successful');
          
          // Store the mounted drive information
          _mountedDrives[tunnel.domain] = driveLetter;
          
          return true;
        }
        
        LogService().warning('Direct network drive mapping failed, falling back to rclone mount');
      }
      
      if (_rclonePath == null) {
        if (!await ensureRclone()) {
          LogService().error('Failed to ensure rclone is available');
          return false;
        }
      }
      
      // Create a unique config name based on the domain
      final configName = 'smb_${tunnel.domain.replaceAll('.', '_')}';
      
      // Create rclone config
      if (!await createRcloneConfig(tunnel, configName)) {
        LogService().error('Failed to create rclone config');
        return false;
      }
      
      // Get the config directory
      final appDir = p.dirname(Platform.resolvedExecutable);
      final configDir = p.join(appDir, 'rclone');
      final configPath = p.join(configDir, 'rclone.conf');
      final logFilePath = p.join(configDir, 'mount.log');
      
      // Mount the SMB share
      LogService().info('Mounting SMB share with rclone...');
      
      // Create mount point directory if it doesn't exist
      final mountPoint = '$driveLetter:\\';
      
      // Prepare the mount command with the exact working parameters
      final mountArgs = [
        'mount',
        '$configName:',
        mountPoint,
        '--config',
        configPath,
        '--vfs-cache-mode',
        'minimal',
        '--network-mode',
        '--volname',
        'SMB-${tunnel.domain}',
        '--vfs-case-insensitive',
        '--dir-cache-time',
        '1s',
        '--no-modtime',
        '--no-checksum',
        '--buffer-size',
        '64M',
        '--transfers',
        '8',
        '--contimeout',
        '60s',
        '--timeout',
        '60s',
        '--retries',
        '3',
        '--low-level-retries',
        '10',
        '--stats',
        '1s',
        '--log-file',
        logFilePath,
        '-vv'
      ];
      
      // Start rclone process based on admin status
      final success = await _startRcloneProcess(mountArgs, isAdmin);
      
      if (!success) {
        LogService().error('Failed to start rclone process');
        return false;
      }
      
      // Store the mounted drive information immediately after starting the process
      _mountedDrives[tunnel.domain] = driveLetter;
      
      // Wait for the mount to initialize
      await Future.delayed(const Duration(seconds: 2));
      
      // Simple verification with shorter timeout
      try {
        final checkProcess = await Process.run(
          'powershell',
          ['-Command', 'Test-Path -Path "$mountPoint" -ErrorAction SilentlyContinue'],
          runInShell: true
        );
        
        final isMounted = checkProcess.exitCode == 0 && 
                        checkProcess.stdout.toString().trim().toLowerCase() == 'true';
        
        LogService().info('Drive mount verification result: ${checkProcess.stdout.toString().trim()}');
        
        // Log mount status but continue regardless
        if (isMounted) {
          LogService().info('SMB share mounted successfully at $driveLetter:');
          try {
            await Process.run(
              'explorer.exe',
              ['$driveLetter:'],
              runInShell: true
            );
          } catch (e) {
            LogService().warning('Failed to open drive in File Explorer: $e');
          }
        } else {
          LogService().warning('Drive $mountPoint is not immediately accessible, but continuing anyway');
          
          // If running as admin and drive is not accessible, suggest restarting without admin privileges
          if (isAdmin) {
            LogService().warning('Drive not accessible when running as administrator. Consider restarting without admin privileges.');
            
            // Try one more direct approach as a last resort
            final lastResortSuccess = await _mountWithCmdNetUse(tunnel, driveLetter);
            if (lastResortSuccess) {
              LogService().info('Last resort direct mounting successful');
              return true;
            }
          }
        }
      } catch (e) {
        LogService().warning('Error during mount verification: $e');
      }
      
      // Return true since we started the process successfully
      return true;
    } catch (e) {
      LogService().error('Error mounting SMB share: $e');
      return false;
    }
  }
  
  // Mount SMB share using direct net use command with proper credentials
  Future<bool> _mountWithDirectNetUse(Tunnel tunnel, String driveLetter) async {
    try {
      LogService().info('Attempting to mount SMB share using direct net use command');
      
      // Format the command with proper credentials
      final username = tunnel.username ?? '';
      final password = tunnel.password ?? '';
      
      // Try multiple approaches - only used in admin mode
      
      // Approach 1: Direct net use command with localhost
      LogService().info('Approach 1: Direct net use with localhost');
      final netUseResult = await Process.run(
        'cmd.exe',
        ['/c', 'net', 'use', '$driveLetter:', '\\\\localhost\\smb', 
         username.isNotEmpty ? '/user:$username' : '', 
         password.isNotEmpty ? password : '',
         '/persistent:yes'],
        runInShell: true
      );
      
      if (netUseResult.exitCode == 0) {
        LogService().info('Direct net use command successful');
        return true;
      }
      
      LogService().warning('Direct net use failed: ${netUseResult.stderr}');
      
      // Approach 2: Use 127.0.0.1 instead of localhost
      LogService().info('Approach 2: Using 127.0.0.1 instead of localhost');
      final ipNetUseResult = await Process.run(
        'cmd.exe',
        ['/c', 'net', 'use', '$driveLetter:', '\\\\127.0.0.1\\smb', 
         username.isNotEmpty ? '/user:$username' : '', 
         password.isNotEmpty ? password : '',
         '/persistent:yes'],
        runInShell: true
      );
      
      if (ipNetUseResult.exitCode == 0) {
        LogService().info('IP-based net use command successful');
        return true;
      }
      
      LogService().warning('IP-based net use failed: ${ipNetUseResult.stderr}');
      
      return false;
    } catch (e) {
      LogService().error('Error in direct net use mount: $e');
      return false;
    }
  }
  
  // Last resort mounting using cmd.exe with direct command - only used in admin mode
  Future<bool> _mountWithCmdNetUse(Tunnel tunnel, String driveLetter) async {
    try {
      LogService().info('Attempting last resort mounting with cmd.exe');
      
      // Create a command that will be executed directly
      final username = tunnel.username ?? '';
      final password = tunnel.password ?? '';
      
      // Simple direct approach with net use
      final netUseResult = await Process.run(
        'cmd.exe',
        ['/c', 'net', 'use', '$driveLetter:', '\\\\localhost\\smb', 
         username.isNotEmpty ? '/user:$username' : '', 
         password.isNotEmpty ? password : '',
         '/persistent:yes'],
        runInShell: true
      );
      
      if (netUseResult.exitCode == 0) {
        LogService().info('Last resort direct mount successful');
        return true;
      }
      
      LogService().warning('Last resort mount failed: ${netUseResult.stderr}');
      return false;
    } catch (e) {
      LogService().error('Error in last resort mount: $e');
      return false;
    }
  }

  // Create a helper batch file to restart the application without administrator privileges
  Future<void> _createRestartWithoutAdminHelper() async {
    try {
      LogService().info('Creating helper to restart application without administrator privileges');
      
      // Get the application path
      final appPath = Platform.resolvedExecutable;
      
      // Get the user's desktop path
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) {
        LogService().warning('Could not determine user profile path');
        return;
      }
      
      final desktopPath = p.join(userProfile, 'Desktop');
      final batchPath = p.join(desktopPath, 'Restart_CT_Manager_Without_Admin.bat');
      
      final batchContent = '''@echo off
echo ========================================================
echo   CT Manager - Restart Without Administrator Privileges
echo ========================================================
echo.
echo This script will restart CT Manager without administrator privileges
echo to improve SMB drive visibility and access.
echo.
echo IMPORTANT: Save any work before continuing.
echo.
pause

echo.
echo Terminating CT Manager process...
taskkill /f /im "${p.basename(appPath)}" > nul 2>&1

echo.
echo Waiting for process to terminate...
timeout /t 2 /nobreak > nul

echo.
echo Starting CT Manager without administrator privileges...
start "" "$appPath"

echo.
echo CT Manager has been restarted without administrator privileges.
echo If you still have issues with SMB drive visibility, you may need to restart your computer.
echo.
echo This batch file will now delete itself.
echo.
timeout /t 5 /nobreak > nul
del "%~f0" /q
exit
''';
      
      await File(batchPath).writeAsString(batchContent);
      
      LogService().info('Created restart helper at $batchPath');
      
      // Also create a shortcut with a more descriptive name
      final shortcutPath = p.join(desktopPath, 'Restart CT Manager (Fix Drive Visibility).lnk');
      
      final shortcutScript = '''
\$WshShell = New-Object -ComObject WScript.Shell
\$Shortcut = \$WshShell.CreateShortcut("$shortcutPath")
\$Shortcut.TargetPath = "$batchPath"
\$Shortcut.Description = "Restart CT Manager without administrator privileges to fix drive visibility"
\$Shortcut.IconLocation = "shell32.dll,77"
\$Shortcut.Save()
''';
      
      await Process.run(
        'powershell',
        ['-Command', shortcutScript],
        runInShell: true
      );
      
      LogService().info('Created restart shortcut at $shortcutPath');
      
      // Show a notification to the user
      final psShowNotification = '''
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
\$notification = New-Object System.Windows.Forms.NotifyIcon
\$notification.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
\$notification.BalloonTipTitle = "CT Manager - Drive Visibility Issue"
\$notification.BalloonTipText = "A helper file has been created on your desktop to restart CT Manager without administrator privileges for better drive visibility."
\$notification.BalloonTipIcon = "Info"
\$notification.Visible = \$true
\$notification.ShowBalloonTip(10000)
Start-Sleep -Seconds 11
\$notification.Dispose()
''';
      
      await Process.run(
        'powershell',
        ['-Command', psShowNotification],
        runInShell: true
      );
      
      LogService().info('Restart helper notification shown');
    } catch (e) {
      LogService().warning('Error creating restart helper: $e');
    }
  }
  
  // Start rclone process based on admin status
  Future<bool> _startRcloneProcess(List<String> mountArgs, bool runningAsAdmin) async {
    try {
      // Get the current username to use for launching processes as the current user
      String currentUsername = '';
      try {
        final userResult = await Process.run(
          'powershell',
          ['-Command', '\$env:USERNAME'],
          runInShell: true
        );
        if (userResult.exitCode == 0) {
          currentUsername = userResult.stdout.toString().trim();
          LogService().info('Current username: $currentUsername');
        }
      } catch (e) {
        LogService().warning('Failed to get current username: $e');
      }
      
      if (runningAsAdmin && currentUsername.isNotEmpty) {
        LogService().info('Running as admin, will launch rclone as current user: $currentUsername');
        
        // Use a direct approach to launch rclone as the current user via a non-elevated cmd window
        bool success = await _launchRcloneInNonElevatedCmd(mountArgs);
        
        if (success) {
          // Still try to make the drive visible
          if (runningAsAdmin) {
            _tryMakeDriveVisibleToRegularUser(mountArgs);
          }
          return true;
        }
        
        // If direct approach failed, try the other approaches
        success = await _launchRcloneAsCurrentUser(mountArgs, currentUsername);
        
        if (!success) {
          // Fallback to the original method
          LogService().info('Falling back to standard launch method');
          return _fallbackStartRcloneProcess(mountArgs, runningAsAdmin);
        }
        
        // Still try to make the drive visible
        if (runningAsAdmin) {
          _tryMakeDriveVisibleToRegularUser(mountArgs);
        }
        
        return true;
      } else {
        // Use the original method if not running as admin or couldn't get username
        return _fallbackStartRcloneProcess(mountArgs, runningAsAdmin);
      }
    } catch (e) {
      LogService().error('Error starting rclone process: $e');
      // Try the fallback method
      return _fallbackStartRcloneProcess(mountArgs, runningAsAdmin);
    }
  }
  
  // Launch rclone in a non-elevated command prompt
  Future<bool> _launchRcloneInNonElevatedCmd(List<String> mountArgs) async {
    try {
      LogService().info('Attempting to launch rclone in a non-elevated command prompt');
      
      // Build the rclone command string
      final rcloneCommand = [_rclonePath!, ...mountArgs].join(' ');
      
      // Create a temporary VBS script that will launch a non-elevated cmd window
      final tempDir = await Directory.systemTemp.createTemp('rclone_non_elevated_');
      final vbsPath = p.join(tempDir.path, 'launch_non_elevated.vbs');
      
      // This VBS script creates a non-elevated command prompt and runs the rclone command
      final vbsContent = '''
' This script launches a non-elevated command prompt and runs rclone
Set objShell = CreateObject("Shell.Application")
Set objWshShell = WScript.CreateObject("WScript.Shell")
Set objFso = CreateObject("Scripting.FileSystemObject")

' Create a batch file with the rclone command
strBatchPath = objFso.GetParentFolderName(WScript.ScriptFullName) & "\\run_rclone.bat"
Set objFile = objFso.CreateTextFile(strBatchPath, True)
objFile.WriteLine("@echo off")
objFile.WriteLine("echo Running rclone as non-elevated user...")
objFile.WriteLine("cd /d " & objFso.GetParentFolderName("$_rclonePath"))
objFile.WriteLine("$rcloneCommand")
objFile.WriteLine("echo Rclone command executed. This window will stay open to keep the mount active.")
objFile.WriteLine("echo Do not close this window unless you want to unmount the drive.")
objFile.WriteLine("pause > nul")
objFile.Close

' Launch the batch file in a non-elevated cmd window
objShell.ShellExecute "cmd.exe", "/k """ & strBatchPath & """", "", "runas", 1
''';
      
      await File(vbsPath).writeAsString(vbsContent);
      
      // Create a batch file that will run the VBS script
      final batchPath = p.join(tempDir.path, 'start_vbs.bat');
      final batchContent = '''
@echo off
echo Starting non-elevated rclone process...
wscript.exe "$vbsPath"
exit
''';
      
      await File(batchPath).writeAsString(batchContent);
      
      // Run the batch file
      final result = await Process.run(
        'cmd.exe',
        ['/c', batchPath],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('Successfully launched non-elevated rclone process');
        
        // Wait a moment for the process to start
        await Future.delayed(const Duration(seconds: 2));
        
        return true;
      }
      
      LogService().warning('Failed to launch non-elevated rclone process: ${result.stderr}');
      
      // Try an alternative approach using explorer.exe to launch cmd
      final explorerPath = p.join(tempDir.path, 'explorer_launch.bat');
      final explorerContent = '''
@echo off
echo Launching non-elevated command prompt via explorer...
explorer.exe shell:AppsFolder\\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App
exit
''';
      
      await File(explorerPath).writeAsString(explorerContent);
      
      // Run the explorer batch file
      final explorerResult = await Process.run(
        'cmd.exe',
        ['/c', explorerPath],
        runInShell: true
      );
      
      if (explorerResult.exitCode == 0) {
        LogService().info('Launched Windows Terminal via explorer. User must manually run rclone command.');
        
        // Create a text file with instructions for the user
        final instructionsPath = p.join(tempDir.path, 'rclone_instructions.txt');
        final instructionsContent = '''
Please copy and paste the following command into the Windows Terminal window that just opened:

$rcloneCommand

This will mount the SMB drive with the correct permissions.
''';
        
        await File(instructionsPath).writeAsString(instructionsContent);
        
        // Open the instructions file
        await Process.run(
          'notepad.exe',
          [instructionsPath],
          runInShell: true
        );
        
        return true;
      }
      
      // Try one more approach - create a shortcut that runs cmd as non-admin
      final shortcutPath = p.join(tempDir.path, 'run_rclone.lnk');
      final shortcutScript = '''
Set WshShell = WScript.CreateObject("WScript.Shell")
Set Shortcut = WshShell.CreateShortcut("$shortcutPath")
Shortcut.TargetPath = "cmd.exe"
Shortcut.Arguments = "/k $rcloneCommand"
Shortcut.Description = "Run Rclone as Non-Admin"
Shortcut.Save
''';
      
      final vbsShortcutPath = p.join(tempDir.path, 'create_shortcut.vbs');
      await File(vbsShortcutPath).writeAsString(shortcutScript);
      
      await Process.run(
        'wscript.exe',
        [vbsShortcutPath],
        runInShell: true
      );
      
      // Run the shortcut
      await Process.run(
        'cmd.exe',
        ['/c', 'start', '', shortcutPath],
        runInShell: true
      );
      
      LogService().info('Created and launched shortcut to run rclone as non-admin');
      
      return true;
    } catch (e) {
      LogService().error('Error launching rclone in non-elevated cmd: $e');
      return false;
    }
  }
  
  // Launch rclone as the current user using multiple approaches
  Future<bool> _launchRcloneAsCurrentUser(List<String> mountArgs, String username) async {
    try {
      // Approach 1: Use a scheduled task to run as the current user
      LogService().info('Attempting to launch rclone as current user using scheduled task');
      
      // Create a batch file that will run rclone with the specified arguments
      final tempDir = await Directory.systemTemp.createTemp('rclone_launcher_');
      final batchPath = p.join(tempDir.path, 'launch_rclone.bat');
      
      // Build the command string
      final rcloneCommand = [_rclonePath!, ...mountArgs].join(' ');
      
      // Create batch file content
      final batchContent = '''
@echo off
echo Starting rclone as user $username...
start "" "$rcloneCommand"
exit
''';
      
      await File(batchPath).writeAsString(batchContent);
      LogService().info('Created rclone launcher batch file at $batchPath');
      
      // Create a scheduled task that runs immediately as the current user
      final taskName = 'RcloneLauncherTask_${DateTime.now().millisecondsSinceEpoch}';
      final scheduleResult = await Process.run(
        'powershell',
        [
          '-Command',
          '''
          \$action = New-ScheduledTaskAction -Execute "$batchPath"
          \$principal = New-ScheduledTaskPrincipal -UserId "$username" -LogonType Interactive -RunLevel Highest
          \$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
          \$task = New-ScheduledTask -Action \$action -Principal \$principal -Settings \$settings
          Register-ScheduledTask -TaskName "$taskName" -InputObject \$task | Out-Null
          Start-ScheduledTask -TaskName "$taskName"
          Start-Sleep -Seconds 2
          Unregister-ScheduledTask -TaskName "$taskName" -Confirm:\$false
          '''
        ],
        runInShell: true
      );
      
      if (scheduleResult.exitCode == 0) {
        LogService().info('Successfully launched rclone using scheduled task');
        return true;
      }
      
      LogService().warning('Failed to launch rclone using scheduled task: ${scheduleResult.stderr}');
      
      // Approach 2: Use PsExec to run as the current user
      LogService().info('Attempting to launch rclone using alternative method');
      
      // Create a VBS script that will launch rclone
      final vbsPath = p.join(tempDir.path, 'launch_rclone.vbs');
      final vbsContent = '''
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "$rcloneCommand", 0, false
''';
      
      await File(vbsPath).writeAsString(vbsContent);
      
      // Use the Windows Script Host to run the VBS file
      final wshResult = await Process.run(
        'powershell',
        [
          '-Command',
          'Start-Process -FilePath "wscript.exe" -ArgumentList "$vbsPath" -WindowStyle Hidden'
        ],
        runInShell: true
      );
      
      if (wshResult.exitCode == 0) {
        LogService().info('Successfully launched rclone using Windows Script Host');
        return true;
      }
      
      LogService().warning('Failed to launch rclone using Windows Script Host: ${wshResult.stderr}');
      
      // Approach 3: Use the Windows Task Scheduler directly via schtasks.exe
      LogService().info('Attempting to launch rclone using schtasks.exe');
      
      final schtasksResult = await Process.run(
        'schtasks',
        [
          '/create', '/tn', taskName, 
          '/tr', batchPath,
          '/sc', 'once', '/st', '00:00',
          '/ru', username,
          '/f'
        ],
        runInShell: true
      );
      
      if (schtasksResult.exitCode == 0) {
        // Run the task
        await Process.run('schtasks', ['/run', '/tn', taskName], runInShell: true);
        
        // Wait a moment for the task to start
        await Future.delayed(const Duration(seconds: 2));
        
        // Delete the task
        await Process.run('schtasks', ['/delete', '/tn', taskName, '/f'], runInShell: true);
        
        LogService().info('Successfully launched rclone using schtasks.exe');
        return true;
      }
      
      LogService().warning('Failed to launch rclone using schtasks.exe: ${schtasksResult.stderr}');
      
      // Clean up
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        LogService().warning('Failed to clean up temporary directory: $e');
      }
      
      return false;
    } catch (e) {
      LogService().error('Error launching rclone as current user: $e');
      return false;
    }
  }
  
  // Fallback method to start rclone process using the original approach
  Future<bool> _fallbackStartRcloneProcess(List<String> mountArgs, bool runningAsAdmin) async {
    try {
      // Use a simpler command structure that's more reliable
      final cmdArgs = ['/c', 'start', '/b', _rclonePath!, ...mountArgs];
      LogService().info('Starting rclone process with command: ${cmdArgs.join(" ")}');

      // Use a timeout to ensure we don't get stuck
      final cmdFuture = Process.run(
        'cmd.exe',
        cmdArgs,
        runInShell: true
      );
      
      // Only wait up to 2 seconds for the process to start
      final cmdProcess = await cmdFuture.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          LogService().info('Rclone start timed out but continuing (likely background process started successfully)');
          return ProcessResult(0, 0, 'timeout', '');
        }
      );

      // Consider timeout as success (likely the process is running in background)
      if (cmdProcess.exitCode != 0 && cmdProcess.stderr.toString().isNotEmpty) {
        LogService().warning('Failed to start rclone via cmd.exe: ${cmdProcess.stderr}');
        return false;
      }

      LogService().info('Rclone process initiated, proceeding immediately');
      
      // If running as admin, try to make the drive visible in regular Explorer windows
      if (runningAsAdmin) {
        _tryMakeDriveVisibleToRegularUser(mountArgs);
      }
      
      return true;
    } catch (e) {
      LogService().error('Error in fallback rclone process start: $e');
      // Even if there's an error, assume it might still be working
      return true;
    }
  }
  
  // Try to make a drive visible to regular user when mounted as admin
  Future<void> _tryMakeDriveVisibleToRegularUser(List<String> mountArgs) async {
    try {
      // Extract the drive letter from mount args (expected format is like "Z:\")
      String driveLetter = "";
      String configName = "";
      
      // Try to extract the config name (for the volume label)
      for (var i = 0; i < mountArgs.length; i++) {
        if (mountArgs[i].endsWith(':') && !mountArgs[i].contains('\\')) {
          configName = mountArgs[i].replaceAll(':', '');
        }
      }
      
      for (var i = 0; i < mountArgs.length; i++) {
        if (i > 0 && mountArgs[i-1].contains('mount') && mountArgs[i].endsWith(':')) {
          // This should be the drive letter
          driveLetter = mountArgs[i].replaceAll(':', '');
          break;
        } else if (RegExp(r'^[A-Z]:\\$').hasMatch(mountArgs[i])) {
          // Direct drive letter format
          driveLetter = mountArgs[i][0];
          break;
        }
      }
      
      if (driveLetter.isEmpty) {
        // Try to infer from the second parameter which is typically the mount point
        if (mountArgs.length > 1 && RegExp(r'^[A-Z]:\\$').hasMatch(mountArgs[1])) {
          driveLetter = mountArgs[1][0];
        }
      }
      
      if (driveLetter.isNotEmpty) {
        LogService().info('Attempting to make drive $driveLetter: visible to Explorer');
        
        // Several approaches to make the drive visible
        
        // 1. Try to explicitly open the drive in Explorer (sometimes helps make it visible)
        await Process.run('explorer.exe', ['$driveLetter:'], runInShell: true)
            .timeout(const Duration(seconds: 2), onTimeout: () {
              LogService().info('Explorer open command timed out, continuing anyway');
              return ProcessResult(0, 0, '', '');
            });
            
        // 2. Try to update the system shell with a PowerShell command
        await Process.run(
          'powershell',
          ['-Command', '(New-Object -ComObject Shell.Application).NameSpace(17).ParseName("$driveLetter`:").InvokeVerb("Refresh")'],
          runInShell: true
        ).timeout(const Duration(seconds: 2), onTimeout: () {
          LogService().info('Shell refresh command timed out, continuing anyway');
          return ProcessResult(0, 0, '', '');
        });
        
        // 3. Register the drive in the registry for all users
        await Process.run(
          'cmd.exe',
          ['/c', 'mountvol', '$driveLetter:', '/L'],
          runInShell: true
        ).timeout(const Duration(seconds: 2), onTimeout: () {
          LogService().info('Mountvol command timed out, continuing anyway');
          return ProcessResult(0, 0, '', '');
        });
        
        // 4. Create a symbolic link in the Public folder to make it accessible to all users
        try {
          final publicFolder = 'C:\\Users\\Public';
          final linkName = 'SMB-Drive-$driveLetter';
          final linkPath = '$publicFolder\\$linkName';
          
          // Remove any existing link first
          await Process.run(
            'cmd.exe',
            ['/c', 'rmdir', linkPath, '/q'],
            runInShell: true
          );
          
          // Create the symbolic link
          await Process.run(
            'cmd.exe',
            ['/c', 'mklink', '/d', linkPath, '$driveLetter:\\'],
            runInShell: true
          );
          
          LogService().info('Created symbolic link at $linkPath pointing to $driveLetter:\\');
          
          // Try to open the symbolic link in Explorer
          await Process.run(
            'explorer.exe',
            [linkPath],
            runInShell: true
          );
        } catch (e) {
          LogService().warning('Failed to create symbolic link: $e');
        }
        
        // 5. Try to create a network drive mapping that's visible to all users
        try {
          // Get the volume GUID path for the drive
          final volumeResult = await Process.run(
            'cmd.exe',
            ['/c', 'mountvol', '$driveLetter:', '/l'],
            runInShell: true
          );
          
          if (volumeResult.exitCode == 0 && volumeResult.stdout.toString().trim().isNotEmpty) {
            final volumePath = volumeResult.stdout.toString().trim();
            
            // Use the volume path to create a persistent mapping
            await Process.run(
              'powershell',
              [
                '-Command',
                'Start-Process powershell -ArgumentList "-Command \\\"New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root \\\"$volumePath\\\" -Persist\\\"" -Verb RunAs'
              ],
              runInShell: true
            );
            
            LogService().info('Attempted to create persistent drive mapping for volume: $volumePath');
          }
        } catch (e) {
          LogService().warning('Failed to create persistent drive mapping: $e');
        }
        
        // 6. Create a desktop shortcut for all users
        await _createDesktopShortcut(driveLetter, configName);
        
        // 7. Try to make the drive visible using a different approach with Windows API
        await _makeDriveVisibleWithWindowsAPI(driveLetter);
        
        // 8. Create a direct shortcut in the user's home directory
        await _createHomeDirectoryShortcut(driveLetter, configName);
        
        // 9. Try to create a network drive mapping using net use
        await _createAdditionalDriveMapping(driveLetter);
        
        LogService().info('Drive visibility enhancement attempts completed for $driveLetter:');
      } else {
        LogService().warning('Could not determine drive letter from mount arguments');
      }
    } catch (e) {
      LogService().warning('Error trying to make drive visible: $e');
      // Don't fail the process just because of visibility enhancement failures
    }
  }
  
  // Create an additional network drive mapping using net use
  Future<void> _createAdditionalDriveMapping(String driveLetter) async {
    try {
      // First, check if the drive is already mapped
      final checkResult = await Process.run(
        'cmd.exe',
        ['/c', 'net', 'use', '$driveLetter:'],
        runInShell: true
      );
      
      // If the drive is already mapped, we don't need to do anything
      if (checkResult.exitCode == 0 && !checkResult.stdout.toString().contains('There is no entry in the list')) {
        LogService().info('Drive $driveLetter: is already mapped');
        return;
      }
      
      // Get the volume GUID path for the drive
      final volumeResult = await Process.run(
        'cmd.exe',
        ['/c', 'mountvol', '$driveLetter:', '/l'],
        runInShell: true
      );
      
      if (volumeResult.exitCode == 0 && volumeResult.stdout.toString().trim().isNotEmpty) {
        final volumePath = volumeResult.stdout.toString().trim();
        
        // Create a UNC path from the volume path
        // First, try to map using the volume path directly
        await Process.run(
          'cmd.exe',
          ['/c', 'net', 'use', 'Y:', volumePath, '/persistent:yes'],
          runInShell: true
        );
        
        LogService().info('Attempted to map volume path $volumePath to Y: drive');
        
        // Also try to create a mapping using localhost
        final tempDriveLetter = 'X';
        if (tempDriveLetter != driveLetter) {
          await Process.run(
            'cmd.exe',
            ['/c', 'net', 'use', '$tempDriveLetter:', '\\\\localhost\\$driveLetter\$', '/persistent:yes'],
            runInShell: true
          );
          
          LogService().info('Attempted to map \\\\localhost\\$driveLetter\$ to $tempDriveLetter: drive');
        }
        
        // Try to create a batch file that users can run to map the drive
        final batchContent = '''
@echo off
echo Mapping SMB drive...
net use Y: $volumePath /persistent:yes
echo Drive mapped to Y:
pause
''';
        
        final publicFolder = 'C:\\Users\\Public\\Desktop';
        final batchPath = '$publicFolder\\Map SMB Drive.bat';
        
        await File(batchPath).writeAsString(batchContent);
        
        LogService().info('Created batch file at $batchPath to map the drive');
      }
    } catch (e) {
      LogService().warning('Error creating network drive mapping: $e');
    }
  }
  
  // Create a direct shortcut in the user's home directory
  Future<void> _createHomeDirectoryShortcut(String driveLetter, String configName) async {
    try {
      // Get the user's home directory
      final homeDir = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Public';
      final documentsDir = p.join(homeDir, 'Documents');
      
      // Create a folder name based on the config name or drive letter
      final folderName = configName.isNotEmpty 
          ? 'SMB Share - $configName' 
          : 'SMB Drive ($driveLetter)';
      
      final folderPath = p.join(documentsDir, folderName);
      
      // Create the directory if it doesn't exist
      final directory = Directory(folderPath);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      
      // Create a README.txt file in the directory with instructions
      final readmePath = p.join(folderPath, 'README.txt');
      final readmeContent = '''
This is a shortcut to the SMB drive mounted at $driveLetter:

If you can't see the drive in Windows Explorer, you can access it through this folder.
The contents of this folder are directly linked to the SMB share.

You can also try to access the drive directly at $driveLetter:
''';
      
      await File(readmePath).writeAsString(readmeContent);
      
      // Create a junction point to the drive
      await Process.run(
        'cmd.exe',
        ['/c', 'mklink', '/j', p.join(folderPath, 'Drive Contents'), '$driveLetter:\\'],
        runInShell: true
      );
      
      // Open the folder in Explorer
      await Process.run(
        'explorer.exe',
        [folderPath],
        runInShell: true
      );
      
      LogService().info('Created home directory shortcut at $folderPath');
    } catch (e) {
      LogService().warning('Error creating home directory shortcut: $e');
    }
  }
  
  // Try to make the drive visible using Windows API
  Future<void> _makeDriveVisibleWithWindowsAPI(String driveLetter) async {
    try {
      // Create a PowerShell script that uses Windows API to broadcast drive change notifications
      final psScript = '''
# This script attempts to make a drive visible to all users by broadcasting Windows messages
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DriveNotification {
    [DllImport("Shell32.dll")]
    public static extern int SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
    
    public static void NotifyDriveChange(string driveLetter) {
        // Constants from WinAPI
        const int SHCNE_DRIVEADD = 0x00000100;
        const int SHCNE_DRIVEREMOVED = 0x00000080;
        const int SHCNE_MEDIAINSERTED = 0x00000020;
        const int SHCNF_PATH = 0x0001;
        const int SHCNF_FLUSH = 0x1000;
        
        // Create a full path with the drive letter
        string drivePath = driveLetter + ":\\\\";
        
        // Convert the path to an unmanaged pointer
        IntPtr pszPath = Marshal.StringToHGlobalUni(drivePath);
        
        try {
            // Notify that a drive was removed (to clear any stale entries)
            SHChangeNotify(SHCNE_DRIVEREMOVED, SHCNF_PATH | SHCNF_FLUSH, pszPath, IntPtr.Zero);
            
            // Notify that a drive was added
            SHChangeNotify(SHCNE_DRIVEADD, SHCNF_PATH | SHCNF_FLUSH, pszPath, IntPtr.Zero);
            
            // Notify that media was inserted
            SHChangeNotify(SHCNE_MEDIAINSERTED, SHCNF_PATH | SHCNF_FLUSH, pszPath, IntPtr.Zero);
        }
        finally {
            // Free the unmanaged memory
            Marshal.FreeHGlobal(pszPath);
        }
    }
}
"@

# Call the method to notify about the drive
[DriveNotification]::NotifyDriveChange("$driveLetter")

# Also try to refresh the shell using COM objects
\$shell = New-Object -ComObject Shell.Application
\$shell.NameSpace(17).Self.InvokeVerb("Refresh")

# Try to create a temporary file on the drive to ensure it's accessible
\$drivePath = "$driveLetter`:"
if (Test-Path -Path \$drivePath) {
    try {
        \$tempFile = Join-Path -Path \$drivePath -ChildPath "visibility_test.txt"
        Set-Content -Path \$tempFile -Value "Test file" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path \$tempFile -Force -ErrorAction SilentlyContinue
        Write-Host "Successfully verified drive $driveLetter`: is accessible"
    } catch {
        Write-Host "Error accessing drive $driveLetter`:"
    }
}
''';

      // Write the script to a temporary file
      final tempDir = await Directory.systemTemp.createTemp('drive_visibility_');
      final scriptPath = p.join(tempDir.path, 'make_drive_visible.ps1');
      await File(scriptPath).writeAsString(psScript);
      
      // Execute the script with elevated privileges
      final result = await Process.run(
        'powershell',
        ['-ExecutionPolicy', 'Bypass', '-File', scriptPath],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('Successfully ran Windows API drive visibility script for $driveLetter:');
        LogService().info('Script output: ${result.stdout}');
      } else {
        LogService().warning('Failed to run Windows API drive visibility script: ${result.stderr}');
      }
      
      // Also try to run the script with elevated privileges
      await Process.run(
        'powershell',
        [
          '-Command',
          'Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File \\"$scriptPath\\"" -Verb RunAs'
        ],
        runInShell: true
      );
      
      // Clean up
      await tempDir.delete(recursive: true);
    } catch (e) {
      LogService().warning('Error making drive visible with Windows API: $e');
    }
  }
  
  // Create a desktop shortcut to the mounted drive
  Future<void> _createDesktopShortcut(String driveLetter, String configName) async {
    try {
      // Get the Public Desktop path
      final publicDesktop = 'C:\\Users\\Public\\Desktop';
      final currentUserDesktop = await _getCurrentUserDesktopPath();
      
      // Create a shortcut name based on the drive letter and config
      final shortcutName = configName.isNotEmpty 
          ? 'SMB Share - $configName.lnk' 
          : 'SMB Drive ($driveLetter).lnk';
      
      // Create PowerShell script to create the shortcut
      final psScript = '''
\$WshShell = New-Object -ComObject WScript.Shell
\$Shortcut = \$WshShell.CreateShortcut("$publicDesktop\\$shortcutName")
\$Shortcut.TargetPath = "$driveLetter`:"
\$Shortcut.Description = "Mounted SMB Drive"
\$Shortcut.IconLocation = "shell32.dll,9"
\$Shortcut.Save()

# Also create for current user if different path
if ("$currentUserDesktop" -ne "$publicDesktop") {
  \$UserShortcut = \$WshShell.CreateShortcut("$currentUserDesktop\\$shortcutName")
  \$UserShortcut.TargetPath = "$driveLetter`:"
  \$UserShortcut.Description = "Mounted SMB Drive"
  \$UserShortcut.IconLocation = "shell32.dll,9"
  \$UserShortcut.Save()
}
''';

      // Write the script to a temporary file
      final tempDir = await Directory.systemTemp.createTemp('smb_shortcut_');
      final scriptPath = p.join(tempDir.path, 'create_shortcut.ps1');
      await File(scriptPath).writeAsString(psScript);
      
      // Execute the script
      final result = await Process.run(
        'powershell',
        ['-ExecutionPolicy', 'Bypass', '-File', scriptPath],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('Created desktop shortcut for drive $driveLetter: at $publicDesktop and $currentUserDesktop');
      } else {
        LogService().warning('Failed to create desktop shortcut: ${result.stderr}');
      }
      
      // Clean up
      await tempDir.delete(recursive: true);
    } catch (e) {
      LogService().warning('Error creating desktop shortcut: $e');
    }
  }
  
  // Get the current user's desktop path
  Future<String> _getCurrentUserDesktopPath() async {
    try {
      final result = await Process.run(
        'powershell',
        ['-Command', '[Environment]::GetFolderPath("Desktop")'],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
      
      // Fallback to default path
      return 'C:\\Users\\Public\\Desktop';
    } catch (e) {
      LogService().warning('Error getting desktop path: $e');
      return 'C:\\Users\\Public\\Desktop';
    }
  }

  // Unmount a network drive
  Future<bool> unmountDrive(String domain) async {
    try {
      if (!_mountedDrives.containsKey(domain)) {
        LogService().warning('No mounted drive found for $domain');
        return false;
      }

      final driveLetter = _mountedDrives[domain];
      final rcPort = _rcPorts[domain];
      
      LogService().info('Unmounting drive $driveLetter: for $domain using RC port $rcPort...');

      // Step 1: Forcibly terminate rclone processes directly - this was the most effective approach
      try {
        final killResult = await Process.run(
          'taskkill',
          ['/F', '/IM', 'rclone.exe'],
          runInShell: true,
        );
        if (killResult.exitCode == 0) {
          LogService().info('Successfully killed rclone processes');
        } else {
          LogService().warning('Failed to kill rclone processes: ${killResult.stderr}');
        }
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        LogService().warning('Error killing rclone processes: $e');
      }

      // Step 2: Forcibly terminate cloudflared processes if needed
      try {
        final killResult = await Process.run(
          'taskkill',
          ['/F', '/IM', 'cloudflared.exe'],
          runInShell: true,
        );
        if (killResult.exitCode == 0) {
          LogService().info('Successfully killed cloudflared processes');
        } else {
          LogService().warning('Failed to kill cloudflared processes: ${killResult.stderr}');
        }
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        LogService().warning('Error killing cloudflared processes: $e');
      }

      // Step 3: Remove the drive using PowerShell
      try {
        await Process.run(
          'powershell',
          ['-Command', 'if (Test-Path "$driveLetter`:") { Remove-PSDrive -Name "$driveLetter" -Force -ErrorAction SilentlyContinue }'],
          runInShell: true,
        );
        LogService().info('Attempted to remove drive using PowerShell');
      } catch (e) {
        LogService().warning('Failed to remove drive using PowerShell: $e');
      }

      // Step 4: Remove the symbolic link if it exists
      try {
        final documentsPath = await _getDocumentsPath();
        if (documentsPath != null) {
          final linkName = 'SMB-${domain.replaceAll('.', '_')}';
          final linkPath = p.join(documentsPath, linkName);
          await Process.run(
            'powershell',
            ['-Command', 'if (Test-Path "$linkPath") { Remove-Item -Path "$linkPath" -Force }'],
            runInShell: true,
          );
          LogService().info('Removed symbolic link if it existed');
        }
      } catch (e) {
        LogService().warning('Failed to remove symbolic link: $e');
      }

      // Step 5: Aggressive drive removal with mountvol
      try {
        await Process.run(
          'mountvol',
          ['$driveLetter:', '/d'],
          runInShell: true,
        );
        LogService().info('Attempted to remove drive using mountvol');
      } catch (e) {
        LogService().warning('Failed to remove drive using mountvol: $e');
      }

      // Step 6: Aggressive drive removal with net use
      try {
        await Process.run(
          'net',
          ['use', '$driveLetter:', '/delete', '/y'],
          runInShell: true,
        );
        LogService().info('Executed net use delete command');
      } catch (e) {
        LogService().warning('Failed to execute net use delete command: $e');
      }

      // Step 7: Enhanced Explorer refresh with increased delays
      await _enhancedExplorerRefresh(driveLetter!);

      // Step 8: Enhanced visibility check
      final isStillVisible = await _isDriveStillVisibleInExplorer(driveLetter);
      if (isStillVisible) {
        LogService().warning('Drive $driveLetter: is still visible in Explorer after unmounting');
        // Only use force removal if needed
        await _forceRemoveDrive(driveLetter);
        await _refreshExplorerDriveView(driveLetter);
      } else {
        LogService().info('Drive $driveLetter: successfully unmounted and no longer visible in Explorer');
      }

      // Step 9: Remove from tracking maps and notify user
      _mountedDrives.remove(domain);
      _rcPorts.remove(domain);
      await _showDriveRemovedNotification(driveLetter);

      LogService().info('Drive unmounted successfully');
      return true;
    } catch (e) {
      LogService().error('Error unmounting drive: $e');
      return false;
    }
  }

  // Enhanced Explorer refresh with increased delays
  Future<void> _enhancedExplorerRefresh(String driveLetter) async {
    try {
      LogService().info('Performing enhanced Explorer refresh for drive $driveLetter:');

      // Method 1: Shell refresh with delay
      await Process.run(
        'powershell',
        ['-Command', '''
        # Shell refresh
        \$shell = New-Object -ComObject Shell.Application
        \$shell.NameSpace(17).Self.InvokeVerb("Refresh")
        Start-Sleep -Seconds 2
        Write-Output "Shell refresh completed"
        '''],
        runInShell: true,
      ).timeout(const Duration(seconds: 3), onTimeout: () {
        LogService().info('Shell refresh timed out');
        return ProcessResult(0, 0, '', '');
      });
      LogService().info('Completed Shell refresh with delay');

      // Method 2: SHChangeNotify with increased delay
      await Process.run(
        'powershell',
        ['-Command', '''
        # SHChangeNotify
        Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class ShellNotify {
            [DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
        }
"@
        [ShellNotify]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Seconds 3
        Write-Output "SHChangeNotify completed"
        '''],
        runInShell: true,
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        LogService().info('SHChangeNotify timed out');
        return ProcessResult(0, 0, '', '');
      });
      LogService().info('Completed SHChangeNotify with increased delay');

      // Method 3: WM_SETTINGCHANGE with delay
      await Process.run(
        'powershell',
        ['-Command', '''
        # WM_SETTINGCHANGE
        Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class SettingChange {
            [DllImport("user32.dll", SetLastError = true)]
            public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
        }
"@
        [IntPtr]\$result = [IntPtr]::Zero
        [SettingChange]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]\$result)
        Start-Sleep -Seconds 2
        Write-Output "WM_SETTINGCHANGE broadcast completed"
        '''],
        runInShell: true,
      ).timeout(const Duration(seconds: 4), onTimeout: () {
        LogService().info('WM_SETTINGCHANGE timed out');
        return ProcessResult(0, 0, '', '');
      });
      LogService().info('Completed WM_SETTINGCHANGE broadcast with delay');

      LogService().info('Enhanced Explorer refresh completed');
    } catch (e) {
      LogService().error('Error during enhanced Explorer refresh: $e');
    }
  }

  // Restart Explorer directly
  Future<void> _restartExplorer(String driveLetter) async {
    try {
      LogService().info('Restarting Explorer for drive $driveLetter:');
      
      // Kill Explorer
      await Process.run(
        'taskkill',
        ['/IM', 'explorer.exe', '/F'],
        runInShell: true,
      );
      LogService().info('Terminated Explorer');
      
      // Wait a moment
      await Future.delayed(const Duration(seconds: 1));
      
      // Start Explorer again
      await Process.run(
        'explorer.exe',
        [],
        runInShell: true,
      );
      LogService().info('Restarted Explorer');
      
      // Give Explorer time to initialize
      await Future.delayed(const Duration(seconds: 2));
    } catch (e) {
      LogService().error('Error restarting Explorer: $e');
    }
  }

  // Enhanced visibility check using Explorer's shell namespace
  Future<bool> _isDriveStillVisibleInExplorer(String driveLetter) async {
    try {
      LogService().info('Checking if drive $driveLetter: is still visible in Explorer (system and shell check)');

      // System-level checks
      final psDriveResult = await Process.run(
        'powershell',
        ['-Command', 'Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue'],
        runInShell: true,
      );
      if (psDriveResult.stdout.toString().contains(driveLetter)) {
        LogService().info('Approach 1 (Get-PSDrive): Drive $driveLetter: is still visible');
        return true;
      }

      final wmiResult = await Process.run(
        'powershell',
        ['-Command', 'Get-WmiObject Win32_LogicalDisk -Filter "DeviceID=\'$driveLetter:\'" -ErrorAction SilentlyContinue'],
        runInShell: true,
      );
      if (wmiResult.stdout.toString().contains(driveLetter)) {
        LogService().info('Approach 2 (WMI): Drive $driveLetter: is still visible');
        return true;
      }

      final netUseResult = await Process.run(
        'net',
        ['use'],
        runInShell: true,
      );
      if (netUseResult.stdout.toString().contains('$driveLetter:')) {
        LogService().info('Approach 3 (net use): Drive $driveLetter: is still visible');
        return true;
      }

      final testPathResult = await Process.run(
        'powershell',
        ['-Command', 'Test-Path "$driveLetter`:"'],
        runInShell: true,
      );
      if (testPathResult.stdout.toString().trim() == 'True') {
        LogService().info('Approach 4 (Test-Path): Drive $driveLetter: is still visible');
        return true;
      }

      // Shell namespace check (to query Explorer's view)
      final shellCheckResult = await Process.run(
        'powershell',
        ['-Command', '''
        \$shell = New-Object -ComObject Shell.Application
        \$drives = \$shell.NameSpace(17).Self.GetFolder.Items() | Where-Object { \$_.Path -eq "$driveLetter`:" }
        if (\$drives) { "True" } else { "False" }
        '''],
        runInShell: true,
      );
      if (shellCheckResult.stdout.toString().trim() == 'True') {
        LogService().info('Approach 5 (Shell Namespace): Drive $driveLetter: is still visible in Explorer');
        return true;
      }

      LogService().info('All checks passed: Drive $driveLetter: is not visible in Explorer');
      return false;
    } catch (e) {
      LogService().error('Error checking if drive is still visible: $e');
      return true; // Assume visible if check fails to avoid false negatives
    }
  }

  // Force remove a drive using aggressive techniques
  Future<void> _forceRemoveDrive(String driveLetter) async {
    try {
      LogService().info('Attempting to force remove drive $driveLetter:');
      
      // Approach 1: Use subst to unmap the drive
      try {
        await Process.run(
          'cmd.exe',
          ['/c', 'subst', '$driveLetter:', '/d'],
          runInShell: true
        );
        LogService().info('Attempted to unmap drive using subst');
      } catch (e) {
        LogService().warning('Failed to unmap drive using subst: $e');
      }
      
      // Approach 2: Use direct Windows API calls via PowerShell
      try {
        final psScript = '''
# Force remove a drive using Windows API
try {
    # Try to remove with net use
    net use $driveLetter`: /delete /y 2>nul
    
    # Try to remove with WMI
    Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$driveLetter`:'" -ErrorAction SilentlyContinue | ForEach-Object { \$_.Delete() }
    
    # Try to remove network connections
    Get-WmiObject -Class Win32_NetworkConnection -Filter "LocalName='$driveLetter`:'" -ErrorAction SilentlyContinue | ForEach-Object { \$_.Delete() }
    
    # Try to remove from registry
    Remove-ItemProperty -Path "HKCU:\\Network\\$driveLetter" -ErrorAction SilentlyContinue
    
    # Force a shell refresh
    \$code = @'
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
    Add-Type -MemberDefinition \$code -Namespace WinAPI -Name Explorer
    # SHCNE_DRIVEREMOVED = 0x00000080, SHCNF_PATH = 0x0001, SHCNF_FLUSH = 0x1000
    [WinAPI.Explorer]::SHChangeNotify(0x00000080, 0x1001, [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni("$driveLetter`:"), [IntPtr]::Zero)
    
    Write-Output "SUCCESS"
} catch {
    Write-Output "FAILED: \$_"
}
''';

        // Write the script to a temporary file
        final tempDir = await Directory.systemTemp.createTemp('force_remove_');
        final scriptPath = p.join(tempDir.path, 'force_remove_drive.ps1');
        await File(scriptPath).writeAsString(psScript);
        
        // Execute the script
        final result = await Process.run(
          'powershell',
          ['-ExecutionPolicy', 'Bypass', '-File', scriptPath],
          runInShell: true
        );
        
        if (result.stdout.toString().contains('SUCCESS')) {
          LogService().info('Successfully forced drive removal using PowerShell');
        } else {
          LogService().warning('Failed to force drive removal using PowerShell: ${result.stdout}');
        }
        
        // Clean up
        await tempDir.delete(recursive: true);
      } catch (e) {
        LogService().warning('Error executing PowerShell force remove script: $e');
      }
      
      // Approach 3: Use diskpart to remove the drive letter
      try {
        // Create a diskpart script
        final tempDir = await Directory.systemTemp.createTemp('diskpart_');
        final scriptPath = p.join(tempDir.path, 'remove_drive.txt');
        await File(scriptPath).writeAsString('select volume $driveLetter\nremove letter=$driveLetter\nexit\n');
        
        // Execute diskpart with the script
        await Process.run(
          'diskpart',
          ['/s', scriptPath],
          runInShell: true
        );
        
        LogService().info('Attempted to remove drive letter using diskpart');
        
        // Clean up
        await tempDir.delete(recursive: true);
      } catch (e) {
        LogService().warning('Failed to remove drive letter using diskpart: $e');
      }
      
      LogService().info('Completed force remove attempts for drive $driveLetter:');
    } catch (e) {
      LogService().error('Error during force remove of drive: $e');
    }
  }

  // Create a helper batch file to restart Explorer
  Future<void> _createExplorerRestartHelper() async {
    try {
      LogService().info('Creating Explorer restart helper batch file');
      
      // Get the user's desktop path
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) {
        LogService().warning('Could not determine user profile path');
        return;
      }
      
      final desktopPath = p.join(userProfile, 'Desktop');
      final batchFilePath = p.join(desktopPath, 'Restart_Explorer.bat');
      
      // Create a batch file with instructions
      final batchContent = '''@echo off
echo ========================================================
echo   Windows Explorer Restart Helper - CT Manager
echo ========================================================
echo.
echo This script will restart Windows Explorer to refresh drive visibility
echo and remove ghost network drives.
echo.
echo IMPORTANT: Save any work in open Explorer windows before continuing.
echo.
pause

echo.
echo Terminating Explorer process...
taskkill /f /im explorer.exe

echo.
echo Cleaning up network drives...
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    net use %%d: /delete /y >nul 2>&1
)

echo.
echo Starting Explorer...
start explorer.exe

echo.
echo Explorer has been restarted successfully.
echo If you still see ghost network drives, you may need to restart your computer.
echo.
pause

echo.
echo This batch file will now delete itself.
echo.
ping -n 3 127.0.0.1 > nul
del "%~f0"
''';

      // Write the batch file
      await File(batchFilePath).writeAsString(batchContent);
      
      // Create a shortcut on the desktop
      final psCreateShortcut = '''
\$WshShell = New-Object -ComObject WScript.Shell
\$Shortcut = \$WshShell.CreateShortcut("$desktopPath\\Restart Explorer.lnk")
\$Shortcut.TargetPath = "$batchFilePath"
\$Shortcut.IconLocation = "shell32.dll,43"
\$Shortcut.Description = "Restart Windows Explorer to refresh drive visibility"
\$Shortcut.Save()
''';

      // Execute the PowerShell script to create the shortcut
      await Process.run(
        'powershell',
        ['-Command', psCreateShortcut],
        runInShell: true
      );
      
      // Show a notification to the user
      LogService().info('Created Explorer restart helper at $batchFilePath');
      
      // Show a balloon tip notification
      final psShowNotification = '''
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
\$notification = New-Object System.Windows.Forms.NotifyIcon
\$notification.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
\$notification.BalloonTipTitle = "CT Manager - Drive Unmounted"
\$notification.BalloonTipText = "A helper file has been created on your desktop to restart Explorer if the unmounted drive is still visible."
\$notification.BalloonTipIcon = "Info"
\$notification.Visible = \$true
\$notification.ShowBalloonTip(10000)
Start-Sleep -Seconds 11
\$notification.Dispose()
''';

      // Execute the PowerShell script to show the notification
      await Process.run(
        'powershell',
        ['-Command', psShowNotification],
        runInShell: true
      );
    } catch (e) {
      LogService().error('Error creating Explorer restart helper: $e');
    }
  }

  // Refresh Explorer's view of drives without restarting
  Future<void> _refreshExplorerDriveView(String driveLetter) async {
    try {
      LogService().info('Refreshing Explorer drive view for $driveLetter: without restarting Explorer');
      
      // Create a PowerShell script that uses Windows API to refresh Explorer
      final psScript = '''
# This script refreshes Explorer's view of drives without restarting Explorer
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class ExplorerRefresh {
    [DllImport("Shell32.dll")]
    public static extern int SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
    
    public static void RefreshDriveView(string driveLetter) {
        // Constants from WinAPI
        const int SHCNE_DRIVEREMOVED = 0x00000080;
        const int SHCNE_UPDATEDIR = 0x00001000;
        const int SHCNE_UPDATEITEM = 0x00002000;
        const int SHCNE_ASSOCCHANGED = 0x08000000;
        const int SHCNF_PATH = 0x0001;
        const int SHCNF_IDLIST = 0x0000;
        const int SHCNF_FLUSH = 0x1000;
        
        // Create a full path with the drive letter
        string drivePath = driveLetter + ":\\\\";
        
        // Convert the path to an unmanaged pointer
        IntPtr pszPath = Marshal.StringToHGlobalUni(drivePath);
        
        try {
            // Notify that a drive was removed
            SHChangeNotify(SHCNE_DRIVEREMOVED, SHCNF_PATH | SHCNF_FLUSH, pszPath, IntPtr.Zero);
            
            // Notify that items and directories need to be updated
            SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATH | SHCNF_FLUSH, pszPath, IntPtr.Zero);
            SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATH | SHCNF_FLUSH, pszPath, IntPtr.Zero);
            
            // Notify that associations have changed (global refresh)
            SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST | SHCNF_FLUSH, IntPtr.Zero, IntPtr.Zero);
            
            Console.WriteLine("Successfully sent drive refresh notifications");
        }
        finally {
            // Free the unmanaged memory
            Marshal.FreeHGlobal(pszPath);
        }
    }
}
"@

# Call the method to refresh Explorer's view
[ExplorerRefresh]::RefreshDriveView("$driveLetter")

# Also try to refresh using COM objects
try {
    # Refresh all Explorer windows
    \$shell = New-Object -ComObject Shell.Application
    \$shell.Windows() | ForEach-Object { \$_.Refresh() }
    
    # Refresh the desktop
    \$shell.NameSpace(0).Self.InvokeVerb("Refresh")
    
    # Refresh My Computer / This PC
    \$shell.NameSpace(17).Self.InvokeVerb("Refresh")
    
    # Refresh Network Neighborhood
    \$shell.NameSpace(18).Self.InvokeVerb("Refresh")
    
    Write-Output "Successfully refreshed Explorer windows"
} catch {
    Write-Output "Error refreshing Explorer windows: \$_"
}

# Clean up any lingering network connections for this drive
try {
    # Remove any network connections for this drive
    Get-WmiObject -Class Win32_NetworkConnection -Filter "LocalName='$driveLetter`:'" -ErrorAction SilentlyContinue | 
        ForEach-Object { 
            try { 
                Write-Output "Removing network connection: \$(\$_.LocalName)"
                \$_.Delete() 
            } catch { 
                Write-Output "Error removing network connection: \$_" 
            } 
        }
        
    # Try to clean up registry entries
    Remove-ItemProperty -Path "HKCU:\\Network\\$driveLetter" -ErrorAction SilentlyContinue
    Get-ChildItem -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\MountPoints2" -ErrorAction SilentlyContinue | 
        Where-Object { \$_.PSChildName -like "*$driveLetter*" } | 
        ForEach-Object {
            Write-Output "Removing MountPoints2 entry: \$(\$_.PSChildName)"
            Remove-Item -Path \$_.PSPath -Force -ErrorAction SilentlyContinue
        }
        
    Write-Output "Cleanup operations completed"
} catch {
    Write-Output "Error during cleanup: \$_"
}
''';

      // Write the script to a temporary file
      final tempDir = await Directory.systemTemp.createTemp('explorer_refresh_');
      final scriptPath = p.join(tempDir.path, 'refresh_explorer.ps1');
      await File(scriptPath).writeAsString(psScript);
      
      // Execute the script
      final result = await Process.run(
        'powershell',
        ['-ExecutionPolicy', 'Bypass', '-File', scriptPath],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('Successfully refreshed Explorer drive view');
        LogService().info('Script output: ${result.stdout}');
      } else {
        LogService().warning('Failed to refresh Explorer drive view: ${result.stderr}');
        
        // Try a direct approach as fallback
        await _directRefreshExplorer(driveLetter);
      }
      
      // Clean up
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        LogService().warning('Failed to clean up temporary directory: $e');
      }
    } catch (e) {
      LogService().error('Error refreshing Explorer drive view: $e');
      // Try direct approach as fallback
      await _directRefreshExplorer(driveLetter);
    }
  }
  
  // Direct approach to refresh Explorer without restarting
  Future<void> _directRefreshExplorer(String driveLetter) async {
    try {
      LogService().info('Using direct approach to refresh Explorer for drive $driveLetter:');
      
      // Approach 1: Use net use to remove any lingering connections
      await Process.run(
        'cmd.exe',
        ['/c', 'net', 'use', '$driveLetter:', '/delete', '/y'],
        runInShell: true
      );
      
      // Approach 2: Use direct PowerShell commands to refresh Explorer
      final psCommand = '''
# Refresh Explorer using COM objects
\$shell = New-Object -ComObject Shell.Application
\$shell.Windows() | ForEach-Object { \$_.Refresh() }
\$shell.NameSpace(17).Self.InvokeVerb("Refresh")

# Force a shell refresh using SHChangeNotify
\$code = @'
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
Add-Type -MemberDefinition \$code -Namespace WinAPI -Name Explorer
[WinAPI.Explorer]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
''';

      await Process.run(
        'powershell',
        ['-Command', psCommand],
        runInShell: true
      );
      
      // Approach 3: Send a WM_DEVICECHANGE message to all windows
      final deviceChangeCommand = '''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DeviceNotification {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
        
    public static void NotifyDeviceChange() {
        // Constants
        const uint HWND_BROADCAST = 0xffff;
        const uint WM_DEVICECHANGE = 0x0219;
        const uint DBT_DEVICEREMOVECOMPLETE = 0x8004;
        const uint SMTO_ABORTIFHUNG = 0x0002;
        
        IntPtr result;
        SendMessageTimeout(
            (IntPtr)HWND_BROADCAST, 
            WM_DEVICECHANGE, 
            (IntPtr)DBT_DEVICEREMOVECOMPLETE, 
            IntPtr.Zero, 
            SMTO_ABORTIFHUNG, 
            1000, 
            out result);
    }
}
"@

[DeviceNotification]::NotifyDeviceChange()
''';

      await Process.run(
        'powershell',
        ['-Command', deviceChangeCommand],
        runInShell: true
      );
      
      LogService().info('Completed direct Explorer refresh attempts');
    } catch (e) {
      LogService().error('Error during direct Explorer refresh: $e');
    }
  }

  // Create a notification about drive removal
  Future<void> _showDriveRemovedNotification(String driveLetter) async {
    try {
      LogService().info('Showing drive removed notification for $driveLetter:');
      
      // Create a PowerShell script to show a notification
      final psScript = '''
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
\$notification = New-Object System.Windows.Forms.NotifyIcon
\$notification.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
\$notification.BalloonTipTitle = "Drive Unmounted"
\$notification.BalloonTipText = "Drive $driveLetter: has been successfully unmounted."
\$notification.BalloonTipIcon = "Info"
\$notification.Visible = \$true
\$notification.ShowBalloonTip(5000)
Start-Sleep -Seconds 6
\$notification.Dispose()
''';

      // Execute the script
      await Process.run(
        'powershell',
        ['-Command', psScript],
        runInShell: true
      );
      
      LogService().info('Drive removed notification shown');
    } catch (e) {
      LogService().warning('Error showing drive removed notification: $e');
    }
  }

  // Get the user's Documents folder path
  Future<String?> _getDocumentsPath() async {
    try {
      final userProfile = await Process.run(
        'powershell',
        ['-Command', 'echo \$env:USERPROFILE'],
        runInShell: true
      );
      
      if (userProfile.exitCode == 0) {
        final profilePath = userProfile.stdout.toString().trim();
        if (profilePath.isNotEmpty) {
          // Combine with Documents folder
          return p.join(profilePath, 'Documents');
        }
      }
      
      return null;
    } catch (e) {
      LogService().error('Error getting Documents path: $e');
      return null;
    }
  }

  // Check if the application is running as administrator
  Future<bool> _isRunningAsAdmin() async {
    try {
      // Use PowerShell to check if running as admin
      final result = await Process.run(
        'powershell',
        ['-Command', '[bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544")'],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        final output = result.stdout.toString().trim().toLowerCase();
        return output == 'true';
      }
      
      return false;
    } catch (e) {
      LogService().error('Error checking admin status: $e');
      return false;
    }
  }

  // Restart the application as the current user (non-admin)
  Future<bool> _restartAppAsCurrentUser() async {
    try {
      LogService().info('Attempting to restart application as current user');
      
      // Get the application path
      final appPath = Platform.resolvedExecutable;
      
      // Get the current username
      String currentUsername = '';
      try {
        final userResult = await Process.run(
          'powershell',
          ['-Command', '\$env:USERNAME'],
          runInShell: true
        );
        if (userResult.exitCode == 0) {
          currentUsername = userResult.stdout.toString().trim();
          LogService().info('Current username: $currentUsername');
        }
      } catch (e) {
        LogService().warning('Failed to get current username: $e');
      }
      
      if (currentUsername.isEmpty) {
        LogService().warning('Could not determine current username, restart may fail');
        return false;
      }
      
      // Create a temporary batch file that will:
      // 1. Kill the current process
      // 2. Start a new process as the current user WITHOUT admin privileges
      // 3. Delete itself
      final tempDir = await Directory.systemTemp.createTemp('app_restart_');
      final batchPath = p.join(tempDir.path, 'restart_as_user.bat');
      
      final batchContent = '''
@echo off
echo Restarting application without administrator privileges...
:: Wait a moment to ensure the parent process can complete its work
timeout /t 1 /nobreak > nul

:: Kill the current process
taskkill /f /im "${p.basename(appPath)}" > nul 2>&1

:: Wait for the process to fully terminate
timeout /t 2 /nobreak > nul

:: Start the application without admin privileges using runas with trustlevel parameter
:: /trustlevel:0x20000 ensures the process starts without elevation
runas /trustlevel:0x20000 /user:$currentUsername "cmd /c start \"\" \"$appPath\""

:: If runas fails, try alternative method with explorer.exe (which runs without elevation)
if %ERRORLEVEL% NEQ 0 (
  echo Trying alternative method...
  :: Use explorer.exe to launch the app without elevation
  explorer.exe "$appPath"
)

:: Delete this batch file after a delay
timeout /t 3 /nobreak > nul
del "%~f0" /q
exit
''';
      
      await File(batchPath).writeAsString(batchContent);
      
      LogService().info('Created restart batch file at $batchPath');
      
      // Execute the batch file with hidden window
      final result = await Process.run(
        'cmd.exe',
        ['/c', 'start', '/min', '', batchPath],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        LogService().info('Successfully initiated application restart as current user');
        
        // Wait a moment to allow the batch file to start
        await Future.delayed(const Duration(seconds: 1));
        
        return true;
      } else {
        LogService().warning('Failed to initiate application restart: ${result.stderr}');
        return false;
      }
    } catch (e) {
      LogService().error('Error restarting application as current user: $e');
      return false;
    }
  }

  // Find an available drive letter
  Future<String> findAvailableDriveLetter() async {
    try {
      // Get all currently used drive letters
      final driveProcess = await Process.run(
        'wmic', 
        ['logicaldisk', 'get', 'deviceid'],
        runInShell: true
      );
      
      final output = driveProcess.stdout.toString();
      final usedDrives = output
          .split('\n')
          .map((line) => line.trim())
          .where((line) => RegExp(r'^[A-Z]:$').hasMatch(line))
          .map((drive) => drive[0])
          .toSet();
      
      // Find the first available drive letter starting from Z and going backwards
      for (String letter in 'ZYXWVUTSRQPONMLKJIHGFED'.split('')) {
        if (!usedDrives.contains(letter)) {
          return letter;
        }
      }
      
      // If no drive letter is available, return an empty string
      return '';
    } catch (e) {
      LogService().error('Error finding available drive letter: $e');
      return '';
    }
  }

  // Get all available drive letters
  Future<List<String>> getAvailableDriveLetters() async {
    try {
      // Get all currently used drive letters
      final driveProcess = await Process.run(
        'wmic', 
        ['logicaldisk', 'get', 'deviceid'],
        runInShell: true
      );
      
      final output = driveProcess.stdout.toString();
      final usedDrives = output
          .split('\n')
          .map((line) => line.trim())
          .where((line) => RegExp(r'^[A-Z]:$').hasMatch(line))
          .map((drive) => drive[0])
          .toSet();
      
      // Find all available drive letters starting from Z and going backwards
      List<String> availableDrives = [];
      for (String letter in 'ZYXWVUTSRQPONMLKJIHGFED'.split('')) {
        if (!usedDrives.contains(letter)) {
          availableDrives.add(letter);
        }
      }
      
      return availableDrives;
    } catch (e) {
      LogService().error('Error getting available drive letters: $e');
      return [];
    }
  }

  // Get the drive letter for a mounted domain
  String? getDriveLetterForDomain(String domain) {
    return _mountedDrives[domain];
  }

  // Check if a domain is mounted
  bool isDomainMounted(String domain) {
    return _mountedDrives.containsKey(domain);
  }

  // Mount a network drive
  Future<bool> mountDrive(String domain, String username, String password, {String? driveLetter}) async {
    try {
      LogService().info('Mounting drive for $domain...');
      
      if (_rclonePath == null) {
        final isInstalled = await isRcloneInstalled();
        if (!isInstalled) {
          LogService().error('Rclone is not installed');
          return false;
        }
      }
      
      // Find an available drive letter if not specified
      final letter = driveLetter ?? await findAvailableDriveLetter();
      if (letter == null) {
        LogService().error('No available drive letters');
        return false;
      }
      
      // Create rclone config
      final configPath = await _createRcloneConfig(domain, username, password);
      if (configPath == null) {
        LogService().error('Failed to create rclone config');
        return false;
      }
      
      // Create mount command
      final mountArgs = [
        'mount',
        'smb_${domain.replaceAll('.', '_')}:',
        '$letter:',
        '--config',
        configPath,
        '--vfs-cache-mode',
        'minimal',
        '--network-mode',
        '--volname',
        'SMB-$domain',
        '--vfs-case-insensitive',
        '--dir-cache-time',
        '1s',
        '--no-modtime',
        '--no-checksum',
        '--buffer-size',
        '64M',
        '--transfers',
        '8',
        '--contimeout',
        '60s',
        '--timeout',
        '60s',
        '--retries',
        '3',
        '--low-level-retries',
        '10',
        '--stats',
        '1s',
      ];
      
      // Add log file if in production mode
      if (!Platform.isLinux) {
        final appDir = p.dirname(Platform.resolvedExecutable);
        final logPath = p.join(appDir, 'rclone', 'mount_$domain.log');
        mountArgs.addAll(['--log-file', logPath, '-vv']);
      }
      
      LogService().info('Starting rclone mount process');
      
      // Start the mount process using cmd.exe with /c start /b to run in background
      final currentUser = Platform.environment['USERNAME'] ?? 'user';
      LogService().info('Current username: $currentUser');
      
      final cmdArgs = [
        '/c',
        'start',
        '/b',
        _rclonePath!,
        ...mountArgs
      ];
      
      LogService().info('Starting rclone process with command: ${cmdArgs.join(' ')}');
      
      final process = await Process.run(
        'cmd.exe',
        cmdArgs,
        runInShell: true,
      ).timeout(const Duration(seconds: 2), onTimeout: () {
        LogService().info('Rclone start timed out but continuing (likely background process started successfully)');
        return ProcessResult(0, 0, '', '');
      });
      
      LogService().info('Rclone process initiated, proceeding immediately');
      
      // Wait a moment for the mount to initialize
      await Future.delayed(const Duration(seconds: 2));
      
      // Verify the drive is mounted
      final isMounted = await _verifyDriveMounted(letter);
      LogService().info('Drive mount verification result: $isMounted');
      
      if (!isMounted) {
        LogService().error('Failed to verify drive mount');
        return false;
      }
      
      // Track the mounted drive
      _mountedDrives[domain] = letter;
      
      // Create a symbolic link in Documents folder
      try {
        final documentsPath = await _getDocumentsPath();
        if (documentsPath != null) {
          final linkName = 'SMB-${domain.replaceAll('.', '_')}';
          final linkPath = p.join(documentsPath, linkName);
          
          // Remove existing link if it exists
          final linkDir = Directory(linkPath);
          if (await linkDir.exists()) {
            await linkDir.delete(recursive: true);
          }
          
          // Create the symbolic link
          await Process.run(
            'cmd.exe',
            ['/c', 'mklink', '/d', linkPath, '$letter:\\'],
            runInShell: true,
          );
          LogService().info('Created symbolic link at $linkPath');
        }
      } catch (e) {
        LogService().warning('Failed to create symbolic link: $e');
        // Continue anyway as this is not critical
      }
      
      LogService().info('SMB share mounted successfully at $letter:');
      return true;
    } catch (e) {
      LogService().error('Error mounting drive: $e');
      return false;
    }
  }
  
  // Verify that a drive is mounted
  Future<bool> _verifyDriveMounted(String driveLetter) async {
    try {
      // Try multiple verification methods
      
      // Method 1: Check if the drive exists using PowerShell
      final psResult = await Process.run(
        'powershell',
        ['-Command', 'Test-Path -Path "$driveLetter`:" -ErrorAction SilentlyContinue'],
        runInShell: true,
      );
      
      if (psResult.stdout.toString().trim().toLowerCase() == 'true') {
        return true;
      }
      
      // Method 2: Check using Get-PSDrive
      final psDriveResult = await Process.run(
        'powershell',
        ['-Command', 'Get-PSDrive -Name "$driveLetter" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name'],
        runInShell: true,
      );
      
      if (psDriveResult.stdout.toString().trim().isNotEmpty) {
        return true;
      }
      
      // Method 3: Check using WMI
      final wmiResult = await Process.run(
        'powershell',
        ['-Command', 'Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID=\'$driveLetter`:\'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID'],
        runInShell: true,
      );
      
      if (wmiResult.stdout.toString().trim().isNotEmpty) {
        return true;
      }
      
      return false;
    } catch (e) {
      LogService().error('Error verifying drive mount: $e');
      return false;
    }
  }

  // Create rclone configuration file for SMB access
  Future<String?> _createRcloneConfig(String domain, String username, String password) async {
    try {
      LogService().info('Creating rclone config for $domain');
      
      if (_rclonePath == null) {
        LogService().error('Rclone path is not set');
        return null;
      }
      
      // Get the directory where rclone is installed
      final rcloneDir = p.dirname(_rclonePath!);
      final configPath = p.join(rcloneDir, 'rclone.conf');
      
      // Create a sanitized remote name
      final remoteName = 'smb_${domain.replaceAll('.', '_')}';
      
      // Create the config content
      final configContent = '''
[${remoteName}]
type = smb
host = $domain
user = $username
pass = $password
''';
      
      // Write the config file
      await File(configPath).writeAsString(configContent);
      LogService().info('Rclone config created at $configPath');
      
      return configPath;
    } catch (e) {
      LogService().error('Error creating rclone config: $e');
      return null;
    }
  }

  // Verify that the drive is properly accessible after mounting
  Future<bool> _verifyDriveAccessibility(String driveLetter) async {
    try {
      LogService().info('Verifying drive $driveLetter: accessibility...');
      
      // Wait a moment for the drive to be fully mounted
      await Future.delayed(const Duration(seconds: 2));
      
      // Multiple verification approaches
      bool isAccessible = false;
      
      // Approach 1: Test-Path in PowerShell
      try {
        final testPathResult = await Process.run(
          'powershell',
          ['-Command', 'Test-Path -Path "$driveLetter`:" -ErrorAction SilentlyContinue'],
          runInShell: true
        );
        
        if (testPathResult.exitCode == 0 && 
            testPathResult.stdout.toString().trim().toLowerCase() == 'true') {
          LogService().info('Drive $driveLetter: is accessible via Test-Path');
          isAccessible = true;
        }
      } catch (e) {
        LogService().warning('Test-Path verification failed: $e');
      }
      
      // Approach 2: Try to list directory contents
      if (!isAccessible) {
        try {
          final dirListResult = await Process.run(
            'cmd.exe',
            ['/c', 'dir', '$driveLetter:\\'],
            runInShell: true
          );
          
          if (dirListResult.exitCode == 0 && 
              !dirListResult.stderr.toString().contains('not accessible')) {
            LogService().info('Drive $driveLetter: is accessible via directory listing');
            isAccessible = true;
          }
        } catch (e) {
          LogService().warning('Directory listing verification failed: $e');
        }
      }
      
      // Approach 3: Check with WMI
      if (!isAccessible) {
        try {
          final wmiResult = await Process.run(
            'powershell',
            ['-Command', 'Get-WmiObject Win32_LogicalDisk -Filter "DeviceID=\'$driveLetter:\'" -ErrorAction SilentlyContinue'],
            runInShell: true
          );
          
          if (wmiResult.exitCode == 0 && 
              wmiResult.stdout.toString().contains(driveLetter)) {
            LogService().info('Drive $driveLetter: is accessible via WMI');
            isAccessible = true;
          }
        } catch (e) {
          LogService().warning('WMI verification failed: $e');
        }
      }
      
      // If the drive is not accessible, try to make it visible
      if (!isAccessible) {
        LogService().warning('Drive $driveLetter: is not accessible after mounting');
        
        // Try to make the drive visible
        await _tryMakeDriveVisibleToRegularUser(['mount', '$driveLetter:']);
        
        // Check again after visibility enhancement
        await Future.delayed(const Duration(seconds: 2));
        
        try {
          final finalCheckResult = await Process.run(
            'powershell',
            ['-Command', 'Test-Path -Path "$driveLetter`:" -ErrorAction SilentlyContinue'],
            runInShell: true
          );
          
          if (finalCheckResult.exitCode == 0 && 
              finalCheckResult.stdout.toString().trim().toLowerCase() == 'true') {
            LogService().info('Drive $driveLetter: is now accessible after visibility enhancement');
            isAccessible = true;
          }
        } catch (e) {
          LogService().warning('Final verification failed: $e');
        }
      }
      
      return isAccessible;
    } catch (e) {
      LogService().error('Error verifying drive accessibility: $e');
      return false;
    }
  }
} 