// lib/models/tunnel.dart

class Tunnel {
  final int? id;
  final String domain;
  final String port;
  final String protocol;
  bool isRunning;
  final bool isLocal;

  Tunnel({
    this.id,
    required this.domain,
    required this.port,
    required this.protocol,
    this.isRunning = false,
    this.isLocal = false,
  });

  String get launchCommand {
    if (protocol == 'RDP') {
      return 'mstsc /v:$domain:$port';
    } else if (protocol == 'SSH') {
      return 'ssh $domain -p $port';
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
    };
  }

  factory Tunnel.fromMap(Map<String, dynamic> map) {
    return Tunnel(
      id: map['id'],
      domain: map['domain'],
      port: map['port'],
      protocol: map['protocol'],
      isLocal: map['is_local'] == 1,
    );
  }

  factory Tunnel.fromJson(Map<String, dynamic> json) => Tunnel(
        id: json['id'] as int?,
        domain: json['domain'] as String,
        port: json['port'] as String,
        protocol: json['protocol'] as String,
        isLocal: json['isLocal'] as bool? ?? false,
        isRunning: json['isRunning'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'domain': domain,
        'port': port,
        'protocol': protocol,
        'isLocal': isLocal,
        'isRunning': isRunning,
      };

  Tunnel copyWith({
    int? id,
    String? domain,
    String? port,
    String? protocol,
    bool? isLocal,
    bool? isRunning,
  }) {
    return Tunnel(
      id: id ?? this.id,
      domain: domain ?? this.domain,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      isLocal: isLocal ?? this.isLocal,
      isRunning: isRunning ?? this.isRunning,
    );
  }
}
