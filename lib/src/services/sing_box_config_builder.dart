import 'dart:convert';

import '../models/vpn_profile.dart';

enum SingBoxConfigTarget { android }

class SingBoxConfigBuilder {
  static const localMixedProxyPort = 20808;

  String build(VpnProfile profile) {
    if (profile.kind == VpnProfileKind.singBoxConfig) {
      final raw = profile.rawConfig;
      if (raw == null || raw.trim().isEmpty) {
        throw StateError('Пустой sing-box config.');
      }
      return raw;
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      throw StateError('У профиля нет outbound-конфига.');
    }

    final proxyOutbound =
        jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    proxyOutbound['tag'] = 'proxy';
    _normalizeOutbound(profile, proxyOutbound);
    _applyDialStability(proxyOutbound);
    final rejectUnsupportedUdp = profile.kind == VpnProfileKind.naive;

    final config = <String, dynamic>{
      'log': {'level': 'warn', 'timestamp': true},
      'dns': _dnsConfig(),
      'inbounds': [_tunInbound(), _mixedInbound()],
      'outbounds': [
        proxyOutbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'action': 'sniff'},
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'protocol': 'dns'},
              {'port': 53},
            ],
            'action': 'hijack-dns',
          },
          _unsupportedUdpRule(rejectUnsupportedUdp),
          {'ip_is_private': true, 'outbound': 'direct'},
        ],
        'default_domain_resolver': 'local-dns',
        'auto_detect_interface': true,
        'final': 'proxy',
      },
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  Map<String, dynamic> _tunInbound() {
    final inbound = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['172.19.0.1/30'],
      'mtu': 1380,
      'auto_route': true,
      'strict_route': true,
      'stack': 'gvisor',
      'endpoint_independent_nat': false,
    };
    inbound['interface_name'] = 'tun0';
    inbound['exclude_package'] = ['online.dnsai.ivanvpn'];
    return inbound;
  }

  Map<String, dynamic> _mixedInbound() {
    return {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': localMixedProxyPort,
    };
  }

  Map<String, dynamic> _dnsConfig() {
    final servers = <Map<String, dynamic>>[
      {'type': 'local', 'tag': 'local-dns'},
      {
        'type': 'fakeip',
        'tag': 'fakeip',
        'inet4_range': '198.18.0.0/15',
        'inet6_range': 'fc00::/18',
      },
      {
        'type': 'https',
        'tag': 'global-dns',
        'server': '1.1.1.1',
        'server_port': 443,
        'path': '/dns-query',
        'tls': {'enabled': true, 'server_name': 'cloudflare-dns.com'},
        'detour': 'proxy',
      },
    ];

    return {
      'servers': servers,
      'rules': [
        {
          'query_type': ['A', 'AAAA'],
          'action': 'route',
          'server': 'fakeip',
        },
      ],
      'strategy': 'ipv4_only',
      'cache_capacity': 8192,
      'reverse_mapping': true,
      'final': 'global-dns',
    };
  }

  Map<String, dynamic> _unsupportedUdpRule(bool rejectAllUdp) {
    return {
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {'port': 853},
        {'protocol': 'stun'},
        {'protocol': 'icmp'},
        if (rejectAllUdp) {'network': 'udp', 'port': 443},
        if (rejectAllUdp) {'network': 'udp'},
      ],
      'action': 'reject',
    };
  }

  void _applyDialStability(Map<String, dynamic> proxyOutbound) {
    proxyOutbound.putIfAbsent('connect_timeout', () => '8s');
    proxyOutbound.putIfAbsent('tcp_keep_alive', () => '3m');
    proxyOutbound.putIfAbsent('tcp_keep_alive_interval', () => '30s');
    proxyOutbound.putIfAbsent('domain_resolver', () => 'local-dns');
    proxyOutbound.putIfAbsent('network_strategy', () => 'fallback');
    proxyOutbound.putIfAbsent('fallback_delay', () => '300ms');
  }

  void _normalizeOutbound(
    VpnProfile profile,
    Map<String, dynamic> proxyOutbound,
  ) {
    if (profile.kind == VpnProfileKind.vlessReality ||
        profile.kind == VpnProfileKind.vlessTls) {
      if (proxyOutbound['network'] == 'tcp') {
        proxyOutbound.remove('network');
      }
      return;
    }

    if (profile.kind != VpnProfileKind.naive) {
      return;
    }

    final originalTls = (proxyOutbound['tls'] as Map?)?.cast<String, dynamic>();
    final outboundType = (proxyOutbound['type'] as String?)?.toLowerCase();
    if (outboundType != 'http') {
      proxyOutbound['type'] = 'naive';
    } else {
      proxyOutbound.remove('extra_headers');
      proxyOutbound.remove('insecure_concurrency');
      proxyOutbound.remove('quic');
      proxyOutbound.remove('quic_congestion_control');
      proxyOutbound.remove('udp_over_tcp');
    }

    final normalizedTls = <String, dynamic>{};
    for (final key in const [
      'server_name',
      'certificate',
      'certificate_path',
      'ech',
    ]) {
      final value = originalTls?[key];
      if (value != null) {
        normalizedTls[key] = value;
      }
    }

    normalizedTls['enabled'] = true;
    normalizedTls.putIfAbsent(
      'server_name',
      () => profile.server ?? proxyOutbound['server'],
    );
    proxyOutbound['tls'] = normalizedTls;
  }
}
