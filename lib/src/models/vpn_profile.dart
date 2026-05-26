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
    this.subscriptionExpiresAt,
  });

  final String id;
  final String name;
  final VpnProfileKind kind;
  final String originalInput;
  final String? server;
  final int? port;
  final Map<String, dynamic>? outbound;
  final String? rawConfig;
  final DateTime? subscriptionExpiresAt;

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
      'subscriptionExpiresAt': subscriptionExpiresAt?.toIso8601String(),
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
      subscriptionExpiresAt: _parseDateTime(json['subscriptionExpiresAt']),
    );
  }

  VpnProfile copyWith({
    String? id,
    String? name,
    VpnProfileKind? kind,
    String? originalInput,
    String? server,
    int? port,
    Map<String, dynamic>? outbound,
    String? rawConfig,
    DateTime? subscriptionExpiresAt,
  }) {
    return VpnProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      originalInput: originalInput ?? this.originalInput,
      server: server ?? this.server,
      port: port ?? this.port,
      outbound: outbound ?? this.outbound,
      rawConfig: rawConfig ?? this.rawConfig,
      subscriptionExpiresAt:
          subscriptionExpiresAt ?? this.subscriptionExpiresAt,
    );
  }

  static DateTime? _parseDateTime(Object? value) {
    return switch (value) {
      DateTime() => value.toUtc(),
      int() => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
      String() => DateTime.tryParse(value)?.toUtc(),
      _ => null,
    };
  }
}
