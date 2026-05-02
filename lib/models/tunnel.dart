// lib/models/tunnel.dart

class DomainForward {
  final int? id;
  final String domain;
  final String port;
  final String protocol;
  final bool isLocal;
  final bool isRunning;
  final String? preferredDriveLetter;
  final bool autoSelectDrive;
  final String? remotePath;
  final bool saveCredentials;

  DomainForward({
    this.id,
    required this.domain,
    required this.port,
    required this.protocol,
    this.isLocal = false,
    this.isRunning = false,
    this.preferredDriveLetter,
    this.autoSelectDrive = true,
    this.remotePath,
    this.saveCredentials = false,
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
      'preferred_drive_letter': preferredDriveLetter,
      'auto_select_drive': autoSelectDrive ? 1 : 0,
      'remote_path': remotePath,
      'save_credentials': saveCredentials ? 1 : 0,
    };
  }

  factory DomainForward.fromMap(Map<String, dynamic> map) {
    return DomainForward(
      id: map['id'],
      domain: map['domain'],
      port: map['port'],
      protocol: map['protocol'],
      isLocal: map['is_local'] == 1,
      isRunning: map['is_running'] == 1,
      preferredDriveLetter: map['preferred_drive_letter'],
      autoSelectDrive: map['auto_select_drive'] == 1,
      remotePath: map['remote_path'],
      saveCredentials: map['save_credentials'] == 1,
    );
  }

  factory DomainForward.fromJson(Map<String, dynamic> json) {
    return DomainForward(
      id: json['id'],
      domain: json['domain'],
      port: json['port'],
      protocol: json['protocol'],
      isLocal: json['is_local'] == 1,
      isRunning: json['is_running'] == 1,
      preferredDriveLetter: json['preferred_drive_letter'],
      autoSelectDrive: json['auto_select_drive'] == 1,
      remotePath: json['remote_path'],
      saveCredentials: json['save_credentials'] == 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'domain': domain,
        'port': port,
        'protocol': protocol,
        'is_local': isLocal ? 1 : 0,
        'is_running': isRunning ? 1 : 0,
        'preferred_drive_letter': preferredDriveLetter,
        'auto_select_drive': autoSelectDrive ? 1 : 0,
        'remote_path': remotePath,
        'save_credentials': saveCredentials ? 1 : 0,
      };

  DomainForward copyWith({
    int? id,
    String? domain,
    String? port,
    String? protocol,
    bool? isLocal,
    bool? isRunning,
    String? preferredDriveLetter,
    bool? autoSelectDrive,
    String? remotePath,
    bool? saveCredentials,
  }) {
    return DomainForward(
      id: id ?? this.id,
      domain: domain ?? this.domain,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      isLocal: isLocal ?? this.isLocal,
      isRunning: isRunning ?? this.isRunning,
      preferredDriveLetter: preferredDriveLetter ?? this.preferredDriveLetter,
      autoSelectDrive: autoSelectDrive ?? this.autoSelectDrive,
      remotePath: remotePath ?? this.remotePath,
      saveCredentials: saveCredentials ?? this.saveCredentials,
    );
  }
}

typedef Tunnel = DomainForward;
