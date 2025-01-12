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
}
