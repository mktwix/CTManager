import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage();

  static Future<void> saveCredentials(String domain, String username, String password) async {
    await _storage.write(key: '${domain}_username', value: username);
    await _storage.write(key: '${domain}_password', value: password);
  }

  static Future<String?> getUsername(String domain) async {
    return await _storage.read(key: '${domain}_username');
  }

  static Future<String?> getPassword(String domain) async {
    return await _storage.read(key: '${domain}_password');
  }

  static Future<void> deleteCredentials(String domain) async {
    await _storage.delete(key: '${domain}_username');
    await _storage.delete(key: '${domain}_password');
  }
}

