import 'dart:convert';

import '../models/vpn_profile.dart';

class XrayBridgeConfig {
  const XrayBridgeConfig({
    required this.xrayConfig,
    required this.localSocksPort,
  });

  final String xrayConfig;
  final int localSocksPort;
}

class XrayConfigBuilder {
  static const defaultLocalSocksPort = 21880;

  XrayBridgeConfig buildBridge(
    VpnProfile profile, {
    int localSocksPort = defaultLocalSocksPort,
  }) {
    if (profile.kind != VpnProfileKind.vlessXhttp &&
        profile.kind != VpnProfileKind.vlessMkcp) {
      throw StateError('Xray bridge is only used for VLESS XHTTP/mKCP.');
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      throw StateError('У профиля нет outbound-конфига.');
    }

    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'local-socks',
          'listen': '127.0.0.1',
          'port': localSocksPort,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': false,
          },
        },
      ],
      'outbounds': [_vlessOutbound(profile, outbound)],
    };

    return XrayBridgeConfig(
      xrayConfig: const JsonEncoder.withIndent('  ').convert(config),
      localSocksPort: localSocksPort,
    );
  }

  Map<String, dynamic> _vlessOutbound(
    VpnProfile profile,
    Map<String, dynamic> outbound,
  ) {
    final uuid = outbound['uuid'] as String?;
    final server = outbound['server'] as String? ?? profile.server;
    final port = outbound['server_port'] as int? ?? profile.port ?? 443;
    if (uuid == null || uuid.isEmpty || server == null || server.isEmpty) {
      throw StateError('VLESS Xray profile is missing uuid/server.');
    }

    final tls = (outbound['tls'] as Map?)?.cast<String, dynamic>();
    final reality = (tls?['reality'] as Map?)?.cast<String, dynamic>();
    final security = reality?['enabled'] == true
        ? 'reality'
        : tls?['enabled'] == true
        ? 'tls'
        : 'none';

    final streamSettings = <String, dynamic>{
      'network': profile.kind == VpnProfileKind.vlessMkcp ? 'kcp' : 'xhttp',
      'security': security,
      if (security == 'tls') 'tlsSettings': _tlsSettings(tls),
      if (security == 'reality') 'realitySettings': _realitySettings(tls),
      if (profile.kind == VpnProfileKind.vlessXhttp)
        'xhttpSettings': _xhttpSettings(outbound),
      if (profile.kind == VpnProfileKind.vlessMkcp)
        'kcpSettings': _kcpSettings(outbound),
    };

    return {
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': server,
            'port': port,
            'users': [
              {
                'id': uuid,
                'encryption': 'none',
                if ((outbound['flow'] as String?)?.isNotEmpty == true)
                  'flow': outbound['flow'],
              },
            ],
          },
        ],
      },
      'streamSettings': streamSettings,
    };
  }

  Map<String, dynamic> _tlsSettings(Map<String, dynamic>? tls) {
    final utls = (tls?['utls'] as Map?)?.cast<String, dynamic>();
    return {
      if ((tls?['server_name'] as String?)?.isNotEmpty == true)
        'serverName': tls!['server_name'],
      if (tls?['insecure'] == true) 'allowInsecure': true,
      if (tls?['alpn'] is List) 'alpn': tls!['alpn'],
      if ((utls?['fingerprint'] as String?)?.isNotEmpty == true)
        'fingerprint': utls!['fingerprint'],
    };
  }

  Map<String, dynamic> _realitySettings(Map<String, dynamic>? tls) {
    final reality = (tls?['reality'] as Map?)?.cast<String, dynamic>() ?? {};
    final utls = (tls?['utls'] as Map?)?.cast<String, dynamic>();
    return {
      if ((tls?['server_name'] as String?)?.isNotEmpty == true)
        'serverName': tls!['server_name'],
      if ((utls?['fingerprint'] as String?)?.isNotEmpty == true)
        'fingerprint': utls!['fingerprint'],
      if ((reality['public_key'] as String?)?.isNotEmpty == true)
        'publicKey': reality['public_key'],
      if ((reality['short_id'] as String?)?.isNotEmpty == true)
        'shortId': reality['short_id'],
    };
  }

  Map<String, dynamic> _xhttpSettings(Map<String, dynamic> outbound) {
    final options =
        (outbound['transport_options'] as Map?)?.cast<String, dynamic>() ?? {};
    return {
      if ((options['path'] as String?)?.isNotEmpty == true)
        'path': options['path'],
      if ((options['host'] as String?)?.isNotEmpty == true)
        'host': options['host'],
      if ((options['mode'] as String?)?.isNotEmpty == true)
        'mode': options['mode']
      else if ((options['xhttpMode'] as String?)?.isNotEmpty == true)
        'mode': options['xhttpMode'],
    };
  }

  Map<String, dynamic> _kcpSettings(Map<String, dynamic> outbound) {
    // Recent Xray-core removed legacy mKCP header/seed settings. Keeping this
    // block empty lets current Xray start; old headerType links may still need
    // server-side migration to the current Xray transport stack.
    return {};
  }
}
