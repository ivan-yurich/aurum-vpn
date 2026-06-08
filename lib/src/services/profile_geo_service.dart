import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/vpn_profile.dart';
import 'sing_box_config_builder.dart';

class ProfileGeo {
  const ProfileGeo({required this.countryCode, this.countryName, this.ip});

  final String countryCode;
  final String? countryName;
  final String? ip;

  String get flag => countryCodeToFlag(countryCode) ?? '🌐';

  static String? countryCodeToFlag(String? value) {
    final code = value?.trim().toUpperCase();
    if (code == null || code.length != 2) {
      return null;
    }

    final first = code.codeUnitAt(0);
    final second = code.codeUnitAt(1);
    if (first < 0x41 || first > 0x5A || second < 0x41 || second > 0x5A) {
      return null;
    }

    return String.fromCharCodes([
      0x1F1E6 + first - 0x41,
      0x1F1E6 + second - 0x41,
    ]);
  }
}

class ProfileGeoService {
  Future<ProfileGeo?> resolveEndpointCountry(VpnProfile profile) async {
    final server = profile.server?.trim();
    if (server == null || server.isEmpty) {
      return null;
    }

    final addresses = <InternetAddress>[];
    final literal = InternetAddress.tryParse(server);
    if (literal != null) {
      addresses.add(literal);
    } else {
      addresses.addAll(
        await InternetAddress.lookup(
          server,
        ).timeout(const Duration(seconds: 4)),
      );
    }

    addresses.sort((a, b) {
      if (a.type == b.type) {
        return 0;
      }
      return a.type == InternetAddressType.IPv4 ? -1 : 1;
    });

    for (final address in addresses.take(2)) {
      final geo = await _lookupIp(address.address, throughTunnel: false);
      if (geo != null) {
        return geo;
      }
    }
    return null;
  }

  Future<ProfileGeo?> resolveExitCountryThroughTunnel() async {
    for (final uri in const [
      'https://ipwho.is/',
      'https://ipapi.co/json/',
      'https://api.country.is/',
    ]) {
      final geo = await _fetchGeo(Uri.parse(uri), throughTunnel: true);
      if (geo != null) {
        return geo;
      }
    }
    return null;
  }

  Future<ProfileGeo?> _lookupIp(
    String ip, {
    required bool throughTunnel,
  }) async {
    for (final uri in [
      Uri.https('ipwho.is', '/$ip'),
      Uri.https('ipapi.co', '/$ip/json/'),
      Uri.https('api.country.is', '/$ip'),
    ]) {
      final geo = await _fetchGeo(uri, throughTunnel: throughTunnel);
      if (geo != null) {
        return geo;
      }
    }
    return null;
  }

  Future<ProfileGeo?> _fetchGeo(Uri uri, {required bool throughTunnel}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = throughTunnel
          ? (_) => 'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}'
          : null;
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'YurichConnect-Geo');
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 7),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final raw = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return _parseGeo(decoded.cast<String, dynamic>());
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  ProfileGeo? _parseGeo(Map<String, dynamic> json) {
    final success = json['success'];
    if (success == false) {
      return null;
    }

    final code =
        (json['country_code'] ??
                json['countryCode'] ??
                json['country_code2'] ??
                json['country'])
            ?.toString()
            .trim()
            .toUpperCase();
    if (code == null || code.length != 2) {
      return null;
    }

    return ProfileGeo(
      countryCode: code,
      countryName:
          (json['country_name'] ?? json['countryName'] ?? json['country'])
              ?.toString(),
      ip: (json['ip'] ?? json['query'])?.toString(),
    );
  }
}
