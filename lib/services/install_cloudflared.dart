// lib/services/install_cloudflared.dart

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'dart:convert';
// Removed unused import
// import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';

final Logger _logger = Logger(
  printer: PrettyPrinter(),
);

class InstallCloudflaredService {
  Future<bool> isCloudflaredInstalled() async {
    try {
      ProcessResult result = await Process.run('cloudflared', ['--version']);
      if (result.exitCode == 0) {
        _logger.i('Cloudflared is installed: ${result.stdout}');
        return true;
      } else {
        _logger.w('Cloudflared is not installed.');
        return false;
      }
    } catch (e) {
      _logger.e('Error checking cloudflared installation: $e');
      return false;
    }
  }

  Future<String?> downloadLatestCloudflared() async {
    try {
      // Fetch latest release info
      final uri = Uri.parse('https://api.github.com/repos/cloudflare/cloudflared/releases/latest');
      final response = await http.get(uri);

      if (response.statusCode != 200) {
        _logger.e('Failed to fetch latest release info: ${response.statusCode}');
        return null;
      }

      final releaseInfo = json.decode(response.body);
      final assets = releaseInfo['assets'] as List<dynamic>;

      // Find the Windows executable
      String? downloadUrl;
      for (var asset in assets) {
        if (asset['name'].toString().toLowerCase().contains('windows') &&
            asset['name'].toString().toLowerCase().endsWith('.exe')) {
          downloadUrl = asset['browser_download_url'];
          break;
        }
      }

      if (downloadUrl == null) {
        _logger.e('Windows executable not found in the latest release.');
        return null;
      }

      _logger.i('Download URL: $downloadUrl');

      // Download the executable
      final downloadResponse = await http.get(Uri.parse(downloadUrl));

      if (downloadResponse.statusCode != 200) {
        _logger.e('Failed to download cloudflared.exe: ${downloadResponse.statusCode}');
        return null;
      }

      // Save the executable to a directory
      Directory appData = await getApplicationSupportDirectory();
      String cloudflaredDirPath = p.join(appData.path, 'cloudflared');
      Directory cloudflaredDir = Directory(cloudflaredDirPath);
      if (!await cloudflaredDir.exists()) {
        await cloudflaredDir.create(recursive: true);
      }

      String exePath = p.join(cloudflaredDirPath, 'cloudflared.exe');
      File exeFile = File(exePath);
      await exeFile.writeAsBytes(downloadResponse.bodyBytes);

      _logger.i('cloudflared.exe downloaded to $exePath');

      return exePath;
    } catch (e) {
      _logger.e('Error downloading cloudflared: $e');
      return null;
    }
  }

  Future<bool> addToUserPath(String directoryPath) async {
    try {
      // Fetch the current user PATH from the registry
      ProcessResult result = await Process.run(
        'reg',
        ['query', 'HKCU\\Environment', '/v', 'Path'],
        runInShell: true,
      );

      String currentPath = '';
      if (result.exitCode == 0) {
        // Parse the registry output
        final lines = result.stdout.toString().split('\n');
        for (var line in lines) {
          if (line.contains('Path')) {
            // Extract the path value
            final parts = line.split(RegExp(r'\s{2,}'));
            if (parts.length >= 3) {
              currentPath = parts[parts.length - 1].trim();
              break;
            }
          }
        }
      }

      // Check if the directory is already in PATH
      List<String> paths = currentPath.split(';');
      if (!paths.contains(directoryPath)) {
        paths.add(directoryPath);
        String newPath = paths.join(';');

        // Set the new PATH
        ProcessResult setResult = await Process.run(
          'reg',
          [
            'add',
            'HKCU\\Environment',
            '/v',
            'Path',
            '/t',
            'REG_EXPAND_SZ',
            '/d',
            newPath,
            '/f'
          ],
          runInShell: true,
        );

        if (setResult.exitCode == 0) {
          _logger.i('Successfully added $directoryPath to user PATH.');
          return true;
        } else {
          _logger.e('Failed to update user PATH: ${setResult.stderr}');
          return false;
        }
      } else {
        _logger.w('$directoryPath is already in user PATH.');
        return true;
      }
    } catch (e) {
      _logger.e('Error updating PATH: $e');
      return false;
    }
  }
}
