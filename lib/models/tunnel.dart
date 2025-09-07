// lib/models/tunnel.dart

class Tunnel {
  final int? id;
  final String domain;
  final String port;
  final String protocol;
  bool isRunning;
  final bool isLocal;
  final String? username;
  final String? password;
  final bool saveCredentials;
  final String? preferredDriveLetter;
  final bool autoSelectDrive;
  final String? remotePath;

  Tunnel({
    this.id,
    required this.domain,
    required this.port,
    required this.protocol,
    this.isRunning = false,
    this.isLocal = false,
    this.username,
    this.password,
    this.saveCredentials = false,
    this.preferredDriveLetter,
    this.autoSelectDrive = true,
    this.remotePath,
  });

  String get launchCommand {
    if (protocol == 'RDP') {
      return 'mstsc /v:localhost:$port';
    } else if (protocol == 'SSH') {
      return 'ssh localhost -p $port';
    } else if (protocol == 'SMB') {
      // SMB doesn't have a direct launch command as it will be mounted as a network drive
      return '';
    }
    return '';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'domain': domain,
      'port': port,
      'protocol': protocol,
      'is_local': isLocal ? 1 : 0,
      'is_running': isRunning ? 1 : 0,
      'username': username,
      'password': password,
      'save_credentials': saveCredentials ? 1 : 0,
      'preferred_drive_letter': preferredDriveLetter,
      'auto_select_drive': autoSelectDrive ? 1 : 0,
      'remote_path': remotePath,
    };
  }

  factory Tunnel.fromMap(Map<String, dynamic> map) {
    return Tunnel(
      id: map['id'],
      domain: map['domain'],
      port: map['port'],
      protocol: map['protocol'],
      isLocal: map['is_local'] == 1,
      isRunning: map['is_running'] == 1,
      username: map['username'],
      password: map['password'],
      saveCredentials: map['save_credentials'] == 1,
      preferredDriveLetter: map['preferred_drive_letter'],
      autoSelectDrive: map['auto_select_drive'] == 1,
      remotePath: map['remote_path'],
    );
  }

  factory Tunnel.fromJson(Map<String, dynamic> json) => Tunnel(
        id: json['id'] as int?,
        domain: json['domain'] as String,
        port: json['port'] as String,
        protocol: json['protocol'] as String,
        isLocal: json['is_local'] == 1 || json['isLocal'] == true,
        isRunning: json['is_running'] == 1 || json['isRunning'] == true,
        username: json['username'] as String?,
        password: json['password'] as String?,
        saveCredentials: json['save_credentials'] == 1 || json['saveCredentials'] == true,
        preferredDriveLetter: json['preferred_drive_letter'] as String?,
        autoSelectDrive: json['auto_select_drive'] == 1 || json['autoSelectDrive'] == true,
        remotePath: json['remote_path'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'domain': domain,
        'port': port,
        'protocol': protocol,
        'is_local': isLocal ? 1 : 0,
        'is_running': isRunning ? 1 : 0,
        'username': username,
        'password': password,
        'save_credentials': saveCredentials ? 1 : 0,
        'preferred_drive_letter': preferredDriveLetter,
        'auto_select_drive': autoSelectDrive ? 1 : 0,
        'remote_path': remotePath,
      };

  Tunnel copyWith({
    int? id,
    String? domain,
    String? port,
    String? protocol,
    bool? isLocal,
    bool? isRunning,
    String? username,
    String? password,
    bool? saveCredentials,
    String? preferredDriveLetter,
    bool? autoSelectDrive,
    String? remotePath,
  }) {
    return Tunnel(
      id: id ?? this.id,
      domain: domain ?? this.domain,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      isLocal: isLocal ?? this.isLocal,
      isRunning: isRunning ?? this.isRunning,
      username: username ?? this.username,
      password: password ?? this.password,
      saveCredentials: saveCredentials ?? this.saveCredentials,
      preferredDriveLetter: preferredDriveLetter ?? this.preferredDriveLetter,
      autoSelectDrive: autoSelectDrive ?? this.autoSelectDrive,
      remotePath: remotePath ?? this.remotePath,
    );
  }
}
