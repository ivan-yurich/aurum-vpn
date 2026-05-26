enum VpnProfileKind {
  vlessReality,
  vlessTls,
  naive,
  hysteria2,
  hysteria,
  singBoxConfig,
}

extension VpnProfileKindLabel on VpnProfileKind {
  String get label => switch (this) {
    VpnProfileKind.vlessReality => 'VLESS Reality',
    VpnProfileKind.vlessTls => 'VLESS TLS',
    VpnProfileKind.naive => 'NaiveProxy',
    VpnProfileKind.hysteria2 => 'Hysteria2',
    VpnProfileKind.hysteria => 'Hysteria',
    VpnProfileKind.singBoxConfig => 'Sing-box',
  };
}

class VpnProfile {
  const VpnProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.originalInput,
    this.server,
    this.port,
    this.outbound,
    this.rawConfig,
  });

  final String id;
  final String name;
  final VpnProfileKind kind;
  final String originalInput;
  final String? server;
  final int? port;
  final Map<String, dynamic>? outbound;
  final String? rawConfig;

  String get endpoint {
    if (server == null || server!.isEmpty) {
      return kind.label;
    }
    return port == null ? server! : '$server:$port';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'kind': kind.name,
      'originalInput': originalInput,
      'server': server,
      'port': port,
      'outbound': outbound,
      'rawConfig': rawConfig,
    };
  }

  factory VpnProfile.fromJson(Map<String, dynamic> json) {
    final kindName =
        json['kind'] as String? ?? VpnProfileKind.vlessReality.name;
    return VpnProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: VpnProfileKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => VpnProfileKind.vlessReality,
      ),
      originalInput: json['originalInput'] as String? ?? '',
      server: json['server'] as String?,
      port: json['port'] as int?,
      outbound: (json['outbound'] as Map?)?.cast<String, dynamic>(),
      rawConfig: json['rawConfig'] as String?,
    );
  }
}
