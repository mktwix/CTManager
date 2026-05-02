import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../models/tunnel.dart';
import '../services/log_service.dart';
import 'smb_exceptions.dart';
import 'dart:convert' as json;

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
  // RC port base — kept for future use, must be <= 65535
  final int _baseRcPort = 5572;

  // Get the next available RC port
  int _getNextRcPort() {
    if (_rcPorts.isEmpty) {
      return _baseRcPort;
    }
    final highestPort = _rcPorts.values.reduce((a, b) => a > b ? a : b);
    return highestPort + 1;
  }

  // Sanitize a domain string into a valid rclone remote name
  String _sanitizeRemoteName(String domain) {
    return 'smb_${domain.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
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
      final response = await http.get(Uri.parse(
          'https://github.com/winfsp/winfsp/releases/download/v2.0/winfsp-2.0.23075.msi'));

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
          'msiexec', ['/i', msiPath, '/qb', '/norestart', 'INSTALLLEVEL=1000'],
          runInShell: true);

      if (installProcess.exitCode != 0) {
        LogService()
            .error('Failed to install WinFsp: ${installProcess.stderr}');
        return false;
      }

      // Clean up the MSI file
      try {
        await File(msiPath).delete();
      } catch (e) {
        LogService().warning('Failed to delete WinFsp installer: $e');
      }

      // Wait longer for installation to complete
      LogService()
          .info('WinFsp installation initiated, waiting for completion...');
      await Future.delayed(const Duration(seconds: 10));

      // Check if WinFsp is now installed
      if (await isWinFspInstalled()) {
        LogService().info('WinFsp installed successfully');
        return true;
      } else {
        LogService().warning(
            'WinFsp installation completed but not detected in registry');

        // Try to check if the WinFsp DLLs exist as an alternative verification
        const winFspDllPath = 'C:\\Program Files\\WinFsp\\bin\\winfsp-x64.dll';
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
      final response = await http.get(Uri.parse(
          'https://downloads.rclone.org/rclone-current-windows-amd64.zip'));

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
          runInShell: true);

      if (extractProcess.exitCode != 0) {
        LogService()
            .error('Failed to extract rclone: ${extractProcess.stderr}');
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
      var result = await Process.run('reg', ['query', 'HKLM\\SOFTWARE\\WinFsp'],
          runInShell: true);

      if (result.exitCode == 0) {
        LogService().info('WinFsp found in 64-bit registry');
        return true;
      }

      // Check 32-bit registry (WOW6432Node)
      result = await Process.run(
          'reg', ['query', 'HKLM\\SOFTWARE\\WOW6432Node\\WinFsp'],
          runInShell: true);

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

  // Create rclone config file — one file per domain to avoid clobbering concurrent mounts
  Future<bool> createRcloneConfig(Tunnel tunnel, String configName,
      String username, String password) async {
    try {
      LogService().info('Creating rclone config for ${tunnel.domain}');

      // Ensure rclone is available
      if (!await ensureRclone()) {
        LogService().error('Rclone is not available, cannot create config');
        return false;
      }

      // Obscure the password using rclone so it is not stored in plaintext
      String obscuredPassword = password;
      try {
        final obscureResult = await Process.run(
          _rclonePath!,
          ['obscure', password],
          runInShell: false,
        );
        if (obscureResult.exitCode == 0) {
          obscuredPassword = obscureResult.stdout.toString().trim();
        } else {
          LogService().warning('rclone obscure failed, using raw password (not recommended)');
        }
      } catch (e) {
        LogService().warning('Could not obscure password: $e');
      }

      // Parse domain from username if it exists (e.g., DOMAIN\User)
      String parsedUsername = username;
      String? parsedDomain;
      if (username.contains('\\')) {
        final parts = username.split('\\');
        parsedDomain = parts[0];
        parsedUsername = parts[1];
      }

      // Create config content with obscured password. Host must be 127.0.0.1 to route through the local Cloudflared tunnel.
      String configContent = '[$configName]\ntype = smb\nhost = 127.0.0.1\nport = ${tunnel.port}\n';
      if (parsedDomain != null) {
        configContent += 'domain = $parsedDomain\n';
      }
      configContent += 'user = $parsedUsername\npass = $obscuredPassword\n';

      // Get config directory — use a per-domain config file
      final appDir = p.dirname(Platform.resolvedExecutable);
      final configDir = p.join(appDir, 'rclone');
      final configPath = p.join(configDir, '$configName.conf');

      // Ensure directory exists
      if (!await Directory(configDir).exists()) {
        await Directory(configDir).create(recursive: true);
      }

      // Write the config file
      await File(configPath).writeAsString(configContent);
      LogService().info('Rclone config created successfully at $configPath');

      return true;
    } catch (e) {
      LogService().error('Error creating rclone config: $e');
      return false;
    }
  }

  // Verify the drive is mounted and accessible

  // Mount an SMB share using rclone
  Future<bool> mountSmbShare(Tunnel tunnel, String driveLetter, String username,
      String password) async {
    // We will now exclusively use the rclone approach as it's more reliable,
    // especially with subfolder paths, and avoids admin-related visibility issues.
    return await _mountWithRclone(tunnel, driveLetter, username, password);
  }

  // Mount SMB share using rclone
  Future<bool> _mountWithRclone(Tunnel tunnel, String driveLetter,
      String username, String password) async {
    try {
      final bool isAdmin = await isRunningAsAdmin();
      if (isAdmin) {
        LogService().warning(
            'Application is running as administrator. This may cause SMB drive visibility issues.');
      }

      // Check for WinFsp first
      if (!await isWinFspInstalled()) {
        final installed = await installWinFsp();
        if (!installed) {
          throw WinFspNotInstalledException(
              'WinFsp is required. Please install it and restart.');
        }
      }

      if (!await ensureRclone()) {
        LogService().error('Failed to ensure rclone is available');
        return false;
      }

      final configName = _sanitizeRemoteName(tunnel.domain);

      if (!await createRcloneConfig(tunnel, configName, username, password)) {
        LogService().error('Failed to create rclone config');
        return false;
      }

      final appDir = p.dirname(Platform.resolvedExecutable);
      final configDir = p.join(appDir, 'rclone');
      // Use per-domain config file
      final configPath = p.join(configDir, '$configName.conf');
      final logFilePath = p.join(configDir, 'mount_$configName.log');

      // Delete log file if it's larger than 10MB to prevent it from growing to 100GB
      try {
        final logFile = File(logFilePath);
        if (await logFile.exists() &&
            await logFile.length() > 10 * 1024 * 1024) {
          await logFile.delete();
          LogService().info('Deleted oversized rclone log file');
        }
      } catch (e) {
        LogService().warning('Failed to check/delete rclone log file: $e');
      }

      final mountPoint = '$driveLetter:\\';
      var remoteSpec = '$configName:';
      if (tunnel.remotePath != null && tunnel.remotePath!.isNotEmpty) {
        remoteSpec += tunnel.remotePath!.replaceAll('\\', '/');
      }

      // Assign a unique RC port for this mount so we can unmount it gracefully
      final rcPort = _getNextRcPort();

      final mountArgs = [
        'mount',
        remoteSpec,
        mountPoint,
        '--config',
        configPath,
        '--vfs-cache-mode',
        'minimal',
        '--network-mode',
        '--volname',
        'SMB-${tunnel.domain}',
        '--log-file',
        logFilePath,
        '--log-level',
        'ERROR',
        '--rc',
        '--rc-addr',
        '127.0.0.1:$rcPort'
      ];

      final success = await _startRcloneProcess(mountArgs, isAdmin);

      if (!success) {
        LogService().error('Failed to start rclone process');
        return false;
      }

      // Track the mount and its RC port
      _mountedDrives[tunnel.domain] = driveLetter;
      _rcPorts[tunnel.domain] = rcPort;

      await Future.delayed(const Duration(seconds: 2));

      return true;
    } catch (e) {
      LogService().error('Error mounting SMB share: $e');
      return false;
    }
  }

  // Start rclone process based on admin status
  Future<bool> _startRcloneProcess(
      List<String> mountArgs, bool runningAsAdmin) async {
    try {
      LogService().info('Starting rclone process...');

      if (runningAsAdmin) {
        LogService().info(
            'App running as Admin - using schtasks to launch rclone as standard user...');

        // Build the full command as a single properly-quoted string for /TR
        // schtasks /TR expects ONE quoted string, not individual args
        final escapedArgs = mountArgs
            .map((arg) => arg.contains(' ') ? '"$arg"' : arg)
            .join(' ');
        // Wrap the entire command (exe + args) in outer quotes for /TR
        final fullCommand = '"\"$_rclonePath\" $escapedArgs"';

        // Identify the logged-on (interactive) user
        final whoamiResult = await Process.run('whoami', [], runInShell: true);
        final currentUser = whoamiResult.stdout.toString().trim();
        LogService().info('Running schtask as user: $currentUser');

        final taskName = 'CTMgrMount_${DateTime.now().millisecondsSinceEpoch}';

        // Register a one-shot task that runs under the standard user token
        final createResult = await Process.run(
          'schtasks',
          [
            '/Create', '/F',
            '/TN', taskName,
            '/TR', fullCommand,
            '/SC', 'ONCE',
            '/ST', '00:00',
            '/RU', currentUser,
          ],
          runInShell: true,
        );

        if (createResult.exitCode != 0) {
          LogService().warning(
              'schtasks /Create failed (${createResult.exitCode}): ${createResult.stderr}. Falling back to direct process launch.');
          await Process.start(_rclonePath!, mountArgs, runInShell: true);
          return true;
        }

        // Trigger the task immediately
        final runResult = await Process.run(
          'schtasks',
          ['/Run', '/TN', taskName],
          runInShell: true,
        );

        if (runResult.exitCode != 0) {
          LogService().warning(
              'schtasks /Run failed (${runResult.exitCode}): ${runResult.stderr}');
        }

        // Give rclone time to start and mount
        await Future.delayed(const Duration(seconds: 4));

        // Delete the temporary task
        try {
          await Process.run(
              'schtasks', ['/Delete', '/F', '/TN', taskName],
              runInShell: true);
        } catch (e) {
          LogService().warning('Failed to delete scheduled task $taskName: $e');
        }
      } else {
        await Process.start(
          _rclonePath!,
          mountArgs,
          runInShell: true,
        );
      }

      return true;
    } catch (e) {
      LogService().error('Failed to start rclone process: $e');
      return false;
    }
  }

  // Open the drive in Explorer securely under the standard user context
  Future<void> openDriveInExplorer(String driveLetter) async {
    try {
      LogService().info('Opening Explorer for drive $driveLetter:');
      await Process.start('explorer.exe', ['$driveLetter:\\']);
    } catch (e) {
      LogService().error('Error opening drive in explorer: $e');
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
      LogService().info('Unmounting drive $driveLetter: for $domain...');

      // Verify this is the correct domain before proceeding
      if (driveLetter == null) {
        LogService().error('No drive letter found for domain $domain');
        return false;
      }

      // Step 1: Graceful unmount via rclone RC 'mount/unmount'.
      // This is the correct WinFsp-aware unmount that tells WinFsp to
      // deregister the volume cleanly before the process exits.
      final rcPort = _rcPorts[domain];
      bool gracefullyUnmounted = false;
      if (rcPort != null && _rclonePath != null) {
        try {
          LogService().info('Attempting graceful unmount via rclone rc mount/unmount on port $rcPort...');
          final rcResult = await Process.run(
            _rclonePath!,
            ['rc', 'mount/unmount', 'mountPoint=$driveLetter:', '--url', '127.0.0.1:$rcPort'],
            runInShell: false,
          ).timeout(const Duration(seconds: 6), onTimeout: () {
            LogService().warning('rclone rc mount/unmount timed out');
            return ProcessResult(0, 1, '', 'timeout');
          });
          if (rcResult.exitCode == 0) {
            LogService().info('Graceful RC unmount succeeded for drive $driveLetter:');
            gracefullyUnmounted = true;
            // Wait for WinFsp to fully deregister and notify Explorer
            await Future.delayed(const Duration(seconds: 2));
          } else {
            LogService().warning('RC unmount failed (exit ${rcResult.exitCode}): ${rcResult.stderr}');
          }
        } catch (e) {
          LogService().warning('Error during RC unmount: $e');
        }
      }

      // Find the specific rclone process for this mount
      String? rclonePid;

      // Helper to safely decode JSON PID output from PowerShell
      String? parsePidJson(String raw) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty) return null;
        try {
          final decoded = json.jsonDecode(trimmed);
          if (decoded is List && decoded.isNotEmpty) return decoded.first.toString();
          if (decoded is int) return decoded.toString();
        } catch (_) {}
        return null;
      }

      try {
        // First try to find by drive letter AND domain
        final findProcessResult = await Process.run(
          'powershell',
          [
            '-Command',
            "Get-CimInstance Win32_Process -Filter \"Name = 'rclone.exe' AND CommandLine LIKE '%$driveLetter:%' AND CommandLine LIKE '%$domain%'\" | Select-Object -ExpandProperty ProcessId | ConvertTo-Json"
          ],
          runInShell: true,
        );
        if (findProcessResult.exitCode == 0) {
          rclonePid = parsePidJson(findProcessResult.stdout.toString());
        }

        // Fallback: find by drive letter only
        if (rclonePid == null) {
          final fallbackResult = await Process.run(
            'powershell',
            [
              '-Command',
              "Get-CimInstance Win32_Process -Filter \"Name = 'rclone.exe' AND CommandLine LIKE '%$driveLetter:%'\" | Select-Object -ExpandProperty ProcessId | ConvertTo-Json"
            ],
            runInShell: true,
          );
          if (fallbackResult.exitCode == 0) {
            rclonePid = parsePidJson(fallbackResult.stdout.toString());
          }
        }
      } catch (e) {
        LogService().warning('Error finding specific rclone process PID: $e');
      }

      // Step 2: Only force-kill rclone if graceful RC unmount failed.
      // Graceful unmount already exits the process cleanly.
      if (!gracefullyUnmounted) {
        LogService().warning('Graceful unmount unavailable, falling back to taskkill for drive $driveLetter:');
        if (rclonePid != null) {
          try {
            LogService().info(
                'Force-killing rclone process with PID $rclonePid for drive $driveLetter:...');
            final killResult = await Process.run(
              'taskkill',
              ['/PID', rclonePid, '/F'],
              runInShell: true,
            );
            if (killResult.exitCode == 0) {
              LogService()
                  .info('Successfully killed rclone process with PID $rclonePid');
            } else {
              LogService().warning(
                  'Failed to kill specific rclone process: ${killResult.stderr}.');
            }
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            LogService()
                .warning('Error killing rclone process with PID $rclonePid: $e');
          }
        } else {
          LogService().warning(
              'Could not find specific rclone process for drive $driveLetter:. Falling back to image name kill.');
          try {
            final killResult = await Process.run(
              'taskkill',
              ['/F', '/IM', 'rclone.exe'],
              runInShell: true,
            );
            if (killResult.exitCode == 0) {
              LogService()
                  .info('Successfully killed rclone processes by image name');
            } else {
              LogService().warning(
                  'Failed to kill rclone processes by image name: ${killResult.stderr}');
            }
          } catch (e) {
            LogService()
                .warning('Error killing rclone processes by image name: $e');
          }
        }
      }

      // Step 2b: Immediately clean up the drive letter from shell namespace
      // FUSE mounts (rclone) register as shell drive letters, not net use entries.
      // We must remove the entry from Explorer's shell namespace explicitly.
      try {
        LogService().info(
            'Removing drive $driveLetter: from shell namespace...');

        // subst /D removes drive letter substitutions (harmless if not subst)
        await Process.run(
          'subst',
          ['$driveLetter:', '/D'],
          runInShell: true,
        );

        // Remove the shell MountPoints2 registry entry for this drive letter
        // This is what causes Explorer to show the ghost after the process dies
        await Process.run(
          'powershell',
          [
            '-Command',
            r'''
              $letter = "''' +
                driveLetter +
                r'''";
              $regPaths = @(
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$($letter):",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##server#$($letter)"
              );
              foreach ($rp in $regPaths) {
                if (Test-Path $rp) { Remove-Item -Path $rp -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "Removed: $rp" }
              }
              # Broadcast SHCNE_DRIVEREMOVED to flush Explorer drive cache
              Add-Type -TypeDefinition @"
              using System;
              using System.Runtime.InteropServices;
              public class SN { [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint e, uint f, IntPtr i1, IntPtr i2); }
"@
              $ptr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni("$($letter):\\");
              [SN]::SHChangeNotify(0x00000080, 0x0005, $ptr, [IntPtr]::Zero);
              [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr);
              Write-Host "SHCNE_DRIVEREMOVED sent for $($letter):"
            '''
          ],
          runInShell: true,
        );
        LogService().info(
            'Shell namespace cleanup complete for $driveLetter:');
      } catch (e) {
        LogService()
            .warning('Failed to clean shell namespace for $driveLetter:: $e');
      }

      // Step 3 (was 2): Remove the drive using PowerShell
      try {
        // First verify the drive is still associated with this domain
        final driveCheck = await Process.run(
          'powershell',
          [
            '-Command',
            'if (Test-Path "$driveLetter`:") { Get-PSDrive -Name "$driveLetter" | Select-Object -ExpandProperty DisplayRoot }'
          ],
          runInShell: true,
        );

        if (driveCheck.exitCode == 0 &&
            driveCheck.stdout.toString().trim().isNotEmpty) {
          final drivePath = driveCheck.stdout.toString().trim();
          LogService().info('Drive $driveLetter: is mapped to: $drivePath');

          // Only remove if it's associated with our domain
          if (drivePath.contains(domain) || drivePath.contains('rclone')) {
            await Process.run(
              'powershell',
              [
                '-Command',
                'if (Test-Path "$driveLetter`:") { Remove-PSDrive -Name "$driveLetter" -Force -ErrorAction SilentlyContinue }'
              ],
              runInShell: true,
            );
            LogService().info('Attempted to remove drive using PowerShell');
          } else {
            LogService().warning(
                'Drive $driveLetter: is not associated with domain $domain, skipping removal');
          }
        }
      } catch (e) {
        LogService().warning('Failed to remove drive using PowerShell: $e');
      }

      // Step 3: Remove the symbolic link if it exists (domain-specific)
      try {
        final documentsPath = await _getDocumentsPath();
        if (documentsPath != null) {
          final linkName = 'SMB-${domain.replaceAll('.', '_')}';
          final linkPath = p.join(documentsPath, linkName);

          // Check if the link exists and is associated with this domain
          final linkCheck = await Process.run(
            'powershell',
            [
              '-Command',
              'if (Test-Path "$linkPath") { Get-Item "$linkPath" | Select-Object -ExpandProperty Target }'
            ],
            runInShell: true,
          );

          if (linkCheck.exitCode == 0 &&
              linkCheck.stdout.toString().trim().isNotEmpty) {
            final targetPath = linkCheck.stdout.toString().trim();
            LogService().info('Symbolic link $linkPath points to: $targetPath');

            // Only remove if it points to our drive
            if (targetPath.contains('$driveLetter:')) {
              await Process.run(
                'powershell',
                [
                  '-Command',
                  'if (Test-Path "$linkPath") { Remove-Item -Path "$linkPath" -Force }'
                ],
                runInShell: true,
              );
              LogService().info('Removed symbolic link for domain $domain');
            } else {
              LogService().info(
                  'Symbolic link is not associated with drive $driveLetter:, skipping removal');
            }
          }
        }
      } catch (e) {
        LogService().warning('Failed to remove symbolic link: $e');
      }

      // Step 4: Aggressive drive removal with mountvol (only if drive is still associated with our domain)
      try {
        // Check if the drive is still associated with our domain before removing
        final mountvolCheck = await Process.run(
          'mountvol',
          ['$driveLetter:', '/l'],
          runInShell: true,
        );

        if (mountvolCheck.exitCode == 0 &&
            mountvolCheck.stdout.toString().trim().isNotEmpty) {
          final volumePath = mountvolCheck.stdout.toString().trim();
          LogService().info('Drive $driveLetter: volume path: $volumePath');

          // Only remove if it's associated with our domain or rclone
          if (volumePath.contains(domain) ||
              volumePath.contains('rclone') ||
              volumePath.contains('SMB')) {
            await Process.run(
              'mountvol',
              ['$driveLetter:', '/d'],
              runInShell: true,
            );
            LogService().info('Attempted to remove drive using mountvol');
          } else {
            LogService().info(
                'Drive $driveLetter: is not associated with domain $domain, skipping mountvol removal');
          }
        }
      } catch (e) {
        LogService().warning('Failed to remove drive using mountvol: $e');
      }

      // Step 5: Aggressive drive removal with net use (only if drive is still associated with our domain)
      try {
        // Check if the drive is still associated with our domain before removing
        final netUseCheck = await Process.run(
          'net',
          ['use', '$driveLetter:'],
          runInShell: true,
        );

        if (netUseCheck.exitCode == 0 &&
            netUseCheck.stdout.toString().contains('$driveLetter:')) {
          final netUseOutput = netUseCheck.stdout.toString();
          LogService()
              .info('Drive $driveLetter: net use output: $netUseOutput');

          // Only remove if it's associated with our domain or rclone
          if (netUseOutput.contains(domain) ||
              netUseOutput.contains('rclone') ||
              netUseOutput.contains('SMB')) {
            await Process.run(
              'net',
              ['use', '$driveLetter:', '/delete', '/y'],
              runInShell: true,
            );
            LogService().info('Executed net use delete command');
          } else {
            LogService().info(
                'Drive $driveLetter: is not associated with domain $domain, skipping net use removal');
          }
        }
      } catch (e) {
        LogService().warning('Failed to execute net use delete command: $e');
      }

      // Step 6: Enhanced Explorer refresh with increased delays
      await _enhancedExplorerRefresh(driveLetter);

      // Step 7: Enhanced visibility check
      final isStillVisible = await _isDriveStillVisibleInExplorer(driveLetter);
      if (isStillVisible) {
        LogService().warning(
            'Drive $driveLetter: is still visible in Explorer after unmounting');
        // Only use force removal if needed
        await _forceRemoveDrive(driveLetter);
        // The refresh call was removed as it's not defined and part of a complex, removed system.
        // await _refreshExplorerDriveView(driveLetter);
      } else {
        LogService().info(
            'Drive $driveLetter: successfully unmounted and no longer visible in Explorer');
      }

      // Step 8: Remove from tracking maps and notify user (only for this specific domain)
      _mountedDrives.remove(domain);
      _rcPorts.remove(domain);
      _showDriveRemovedNotification(driveLetter); // fire-and-forget, non-blocking

      LogService().info('Drive unmounted successfully for domain $domain');
      return true;
    } catch (e) {
      LogService().error('Error unmounting drive: $e');
      return false;
    }
  }

  // Enhanced Explorer refresh with increased delays
  Future<void> _enhancedExplorerRefresh(String driveLetter) async {
    try {
      LogService()
          .info('Performing enhanced Explorer refresh for drive $driveLetter:');

      // Method 1: Shell refresh with delay
      await Process.run(
        'powershell',
        [
          '-Command',
          '''
        # Shell refresh
        \$shell = New-Object -ComObject Shell.Application
        \$shell.NameSpace(17).Self.InvokeVerb("Refresh")
        Start-Sleep -Seconds 2
        Write-Output "Shell refresh completed"
        '''
        ],
        runInShell: true,
      ).timeout(const Duration(seconds: 3), onTimeout: () {
        LogService().info('Shell refresh timed out');
        return ProcessResult(0, 0, '', '');
      });
      LogService().info('Completed Shell refresh with delay');

      // Method 2: SHChangeNotify with increased delay
      await Process.run(
        'powershell',
        [
          '-Command',
          '''
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
        '''
        ],
        runInShell: true,
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        LogService().info('SHChangeNotify timed out');
        return ProcessResult(0, 0, '', '');
      });
      LogService().info('Completed SHChangeNotify with increased delay');

      // Method 3: WM_SETTINGCHANGE with delay
      await Process.run(
        'powershell',
        [
          '-Command',
          '''
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
        '''
        ],
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

  // _restartExplorer intentionally removed — killing Explorer is too disruptive
  // and was never called in the main flow.

  // Enhanced visibility check using Explorer's shell namespace
  Future<bool> _isDriveStillVisibleInExplorer(String driveLetter) async {
    try {
      LogService().info(
          'Checking if drive $driveLetter: is still visible in Explorer (system and shell check)');

      // System-level checks
      final psDriveResult = await Process.run(
        'powershell',
        [
          '-Command',
          'Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue'
        ],
        runInShell: true,
      );
      if (psDriveResult.stdout.toString().contains(driveLetter)) {
        LogService().info(
            'Approach 1 (Get-PSDrive): Drive $driveLetter: is still visible');
        return true;
      }

      final wmiResult = await Process.run(
        'powershell',
        [
          '-Command',
          'Get-WmiObject Win32_LogicalDisk -Filter "DeviceID=\'$driveLetter:\'" -ErrorAction SilentlyContinue'
        ],
        runInShell: true,
      );
      if (wmiResult.stdout.toString().contains(driveLetter)) {
        LogService()
            .info('Approach 2 (WMI): Drive $driveLetter: is still visible');
        return true;
      }

      final netUseResult = await Process.run(
        'net',
        ['use'],
        runInShell: true,
      );
      if (netUseResult.stdout.toString().contains('$driveLetter:')) {
        LogService()
            .info('Approach 3 (net use): Drive $driveLetter: is still visible');
        return true;
      }

      final testPathResult = await Process.run(
        'powershell',
        ['-Command', 'Test-Path "$driveLetter`:"'],
        runInShell: true,
      );
      if (testPathResult.stdout.toString().trim() == 'True') {
        LogService().info(
            'Approach 4 (Test-Path): Drive $driveLetter: is still visible');
        return true;
      }

      // Shell namespace check (to query Explorer's view)
      final shellCheckResult = await Process.run(
        'powershell',
        [
          '-Command',
          '''
        \$shell = New-Object -ComObject Shell.Application
        \$drives = \$shell.NameSpace(17).Self.GetFolder.Items() | Where-Object { \$_.Path -eq "$driveLetter`:" }
        if (\$drives) { "True" } else { "False" }
        '''
        ],
        runInShell: true,
      );
      if (shellCheckResult.stdout.toString().trim() == 'True') {
        LogService().info(
            'Approach 5 (Shell Namespace): Drive $driveLetter: is still visible in Explorer');
        return true;
      }

      LogService().info(
          'All checks passed: Drive $driveLetter: is not visible in Explorer');
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
        await Process.run('cmd.exe', ['/c', 'subst', '$driveLetter:', '/d'],
            runInShell: true);
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
    [WinAPI.Explorer]::SHChangeNotify(0x00000080, 0x1001, [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni("$driveLetter`:\\"), [IntPtr]::Zero)
    
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
            'powershell', ['-ExecutionPolicy', 'Bypass', '-File', scriptPath],
            runInShell: true);

        if (result.stdout.toString().contains('SUCCESS')) {
          LogService()
              .info('Successfully forced drive removal using PowerShell');
        } else {
          LogService().warning(
              'Failed to force drive removal using PowerShell: ${result.stdout}');
        }

        // Clean up
        await tempDir.delete(recursive: true);
      } catch (e) {
        LogService()
            .warning('Error executing PowerShell force remove script: $e');
      }

      // Approach 3: Use diskpart to remove the drive letter
      try {
        // Create a diskpart script
        final tempDir = await Directory.systemTemp.createTemp('diskpart_');
        final scriptPath = p.join(tempDir.path, 'remove_drive.txt');
        await File(scriptPath).writeAsString(
            'select volume $driveLetter\nremove letter=$driveLetter\nexit\n');

        // Execute diskpart with the script
        await Process.run('diskpart', ['/s', scriptPath], runInShell: true);

        LogService().info('Attempted to remove drive letter using diskpart');

        // Clean up
        await tempDir.delete(recursive: true);
      } catch (e) {
        LogService()
            .warning('Failed to remove drive letter using diskpart: $e');
      }

      LogService()
          .info('Completed force remove attempts for drive $driveLetter:');
    } catch (e) {
      LogService().error('Error during force remove of drive: $e');
    }
  }

  // Create a notification about drive removal — fire and forget, does NOT block
  void _showDriveRemovedNotification(String driveLetter) {
    LogService().info('Showing drive removed notification for $driveLetter:');

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

    // Fire and forget — do NOT await so the caller is not blocked for 6 seconds
    Process.start('powershell', ['-Command', psScript], runInShell: true)
        .then((_) {})
        .catchError((Object e) {
      LogService().warning('Error showing drive removed notification: $e');
    });
  }

  // Get the user's Documents folder path
  Future<String?> _getDocumentsPath() async {
    try {
      final userProfile = await Process.run(
          'powershell', ['-Command', 'echo \$env:USERPROFILE'],
          runInShell: true);

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
  Future<bool> isRunningAsAdmin() async {
    try {
      // Use the WindowsPrincipal IsInRole check — more reliable than SID string matching
      final result = await Process.run(
          'powershell',
          [
            '-Command',
            '([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)'
          ],
          runInShell: true);

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

  // Get all used drive letters via PowerShell Get-PSDrive (wmic is deprecated on Win11)
  Future<Set<String>> _getUsedDriveLetters() async {
    final result = await Process.run(
      'powershell',
      ['-Command', 'Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name'],
      runInShell: true,
    );
    if (result.exitCode != 0) return {};
    return result.stdout
        .toString()
        .split('\n')
        .map((l) => l.trim().toUpperCase())
        .where((l) => RegExp(r'^[A-Z]$').hasMatch(l))
        .toSet();
  }

  // Find an available drive letter (Z → D)
  Future<String> findAvailableDriveLetter() async {
    try {
      final usedDrives = await _getUsedDriveLetters();
      for (final letter in 'ZYXWVUTSRQPONMLKJIHGFED'.split('')) {
        if (!usedDrives.contains(letter)) return letter;
      }
      return '';
    } catch (e) {
      LogService().error('Error finding available drive letter: $e');
      return '';
    }
  }

  // Get all available drive letters (Z → D)
  Future<List<String>> getAvailableDriveLetters() async {
    try {
      final usedDrives = await _getUsedDriveLetters();
      return 'ZYXWVUTSRQPONMLKJIHGFED'
          .split('')
          .where((l) => !usedDrives.contains(l))
          .toList();
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

  // Manually track a drive (used for re-syncing from OS)
  void trackMountedDrive(String domain, String driveLetter) {
    _mountedDrives[domain] = driveLetter;
  }

  // Check the OS for a mounted drive by domain
  Future<bool> verifyDriveMountedForDomain(String domain) async {
    try {
      final result = await Process.run(
        'powershell',
        [
          '-Command',
          "Get-PSDrive | Where-Object { \$_.DisplayRoot -like '*$domain*' } | Select-Object -ExpandProperty Name"
        ],
        runInShell: true,
      );
      return result.stdout.toString().trim().isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Get the drive letter from the OS for a specific domain
  Future<String?> getDriveLetterFromOS(String domain) async {
    try {
      final result = await Process.run(
        'powershell',
        [
          '-Command',
          "Get-PSDrive | Where-Object { \$_.DisplayRoot -like '*$domain*' } | Select-Object -ExpandProperty Name"
        ],
        runInShell: true,
      );
      final letter = result.stdout.toString().trim();
      return letter.isNotEmpty ? letter : null;
    } catch (e) {
      return null;
    }
  }

  // Mount a network drive
  Future<bool> mountDrive(String domain, String username, String password,
      {String? driveLetter}) async {
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

      final cmdArgs = ['/c', 'start', '/b', _rclonePath!, ...mountArgs];

      LogService()
          .info('Starting rclone process with command: ${cmdArgs.join(' ')}');

      // Start the mount process using cmd.exe with /c start /b to run in background
      // We don't use the result — the child process detaches immediately
      await Process.run(
        'cmd.exe',
        cmdArgs,
        runInShell: true,
      ).timeout(const Duration(seconds: 2), onTimeout: () {
        LogService().info(
            'Rclone start timed out but continuing (likely background process started successfully)');
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
        [
          '-Command',
          'Test-Path -Path "$driveLetter`:" -ErrorAction SilentlyContinue'
        ],
        runInShell: true,
      );

      if (psResult.stdout.toString().trim().toLowerCase() == 'true') {
        return true;
      }

      // Method 2: Check using Get-PSDrive
      final psDriveResult = await Process.run(
        'powershell',
        [
          '-Command',
          'Get-PSDrive -Name "$driveLetter" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name'
        ],
        runInShell: true,
      );

      if (psDriveResult.stdout.toString().trim().isNotEmpty) {
        return true;
      }

      // Method 3: Check using WMI
      final wmiResult = await Process.run(
        'powershell',
        [
          '-Command',
          'Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID=\'$driveLetter`:\'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID'
        ],
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

  // Create rclone configuration file for SMB access - DEPRECATED
  Future<String?> _createRcloneConfig(
      String domain, String username, String password) async {
    try {
      LogService().warning("_createRcloneConfig is deprecated.");
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
[$remoteName]
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
  Future<bool> verifyDriveAccessibility(String driveLetter) async {
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
            [
              '-Command',
              'Test-Path -Path "$driveLetter`:\\" -ErrorAction SilentlyContinue'
            ],
            runInShell: true).timeout(const Duration(seconds: 3));

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
              'cmd.exe', ['/c', 'dir', '$driveLetter:\\'],
              runInShell: true).timeout(const Duration(seconds: 3));

          if (dirListResult.exitCode == 0 &&
              !dirListResult.stderr.toString().contains('not accessible')) {
            LogService().info(
                'Drive $driveLetter: is accessible via directory listing');
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
              [
                '-Command',
                'Get-WmiObject Win32_LogicalDisk -Filter "DeviceID=\'$driveLetter:\'" -ErrorAction SilentlyContinue'
              ],
              runInShell: true).timeout(const Duration(seconds: 3));

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
        LogService()
            .warning('Drive $driveLetter: is not accessible after mounting');

        // Try to make the drive visible (legacy method removed)
        LogService()
            .warning('Drive visibility enhancement handled by startup script');

        // Check again after visibility enhancement
        await Future.delayed(const Duration(seconds: 2));

        try {
          final finalCheckResult = await Process.run(
              'powershell',
              [
                '-Command',
                'Test-Path -Path "$driveLetter`:\\" -ErrorAction SilentlyContinue'
              ],
              runInShell: true).timeout(const Duration(seconds: 3));

          if (finalCheckResult.exitCode == 0 &&
              finalCheckResult.stdout.toString().trim().toLowerCase() ==
                  'true') {
            LogService().info(
                'Drive $driveLetter: is now accessible after visibility enhancement');
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
