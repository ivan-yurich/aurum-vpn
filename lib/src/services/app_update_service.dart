import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const _releaseApiUrls = [
  'https://ivan-it.net/aurum-vpn/android/latest.json',
  'https://api.github.com/repos/ivan-yurich/aurum-vpn/releases/latest',
];

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.assetName,
    required this.downloadUrl,
    required this.size,
  });

  final String version;
  final String assetName;
  final Uri downloadUrl;
  final int? size;
}

class AppUpdatePermissionException implements Exception {
  const AppUpdatePermissionException();

  @override
  String toString() => 'Install permission is required.';
}

class AppUpdateService {
  AppUpdateService({HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 7);
  }

  static const _channel = MethodChannel('online.dnsai.ivanvpn/updater');

  final HttpClient _client;

  Future<List<String>> supportedAbis() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    final value = await _channel.invokeMethod<List<Object?>>(
      'getSupportedAbis',
    );
    return value?.whereType<String>().toList(growable: false) ?? const [];
  }

  Future<AppUpdateInfo?> findLatest({
    required String currentVersion,
    required List<String> supportedAbis,
  }) async {
    Object? lastError;
    var sawEmptyEndpoint = false;
    for (final value in _releaseApiUrls) {
      try {
        final release = await _fetchRelease(Uri.parse(value), supportedAbis);
        if (release == null) {
          sawEmptyEndpoint = true;
          continue;
        }
        return _isVersionNewer(release.version, currentVersion)
            ? release
            : null;
      } on Object catch (error) {
        lastError = error;
      }
    }

    if (lastError != null && !sawEmptyEndpoint) {
      throw StateError('$lastError');
    }
    return null;
  }

  Future<File> download(
    AppUpdateInfo update, {
    required void Function(double? progress) onProgress,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('aurum_update_');
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}${update.assetName}',
    );
    final request = await _client.getUrl(update.downloadUrl);
    request.headers.set(HttpHeaders.userAgentHeader, 'AurumVPN-Updater');
    request.followRedirects = true;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}');
    }

    final sink = file.openWrite();
    var received = 0;
    final total = response.contentLength > 0
        ? response.contentLength
        : update.size;
    try {
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (total != null && total > 0) {
          onProgress((received / total).clamp(0, 1).toDouble());
        } else {
          onProgress(null);
        }
      }
    } finally {
      await sink.close();
    }
    onProgress(1);
    return file;
  }

  Future<void> installApk(File file) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': file.path});
    } on PlatformException catch (error) {
      if (error.code == 'INSTALL_PERMISSION') {
        throw const AppUpdatePermissionException();
      }
      rethrow;
    }
  }

  Future<void> openInstallSettings() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openInstallSettings');
    }
  }

  Future<AppUpdateInfo?> _fetchRelease(
    Uri uri,
    List<String> supportedAbis,
  ) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.userAgentHeader, 'AurumVPN-Updater');
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode == HttpStatus.notFound) {
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Update endpoint HTTP ${response.statusCode}');
    }

    final raw = await utf8.decodeStream(response);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final version = (json['version'] ?? json['tag_name'] ?? json['name'] ?? '')
        .toString();
    if (version.trim().isEmpty) {
      throw StateError('Update endpoint has no version.');
    }

    final assets = (json['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
    final selected = _selectAsset(assets, supportedAbis);
    if (selected == null) {
      return null;
    }

    final downloadUrl =
        (selected['download_url'] ?? selected['browser_download_url'] ?? '')
            .toString();
    if (downloadUrl.isEmpty) {
      throw StateError('Update asset has no download URL.');
    }

    return AppUpdateInfo(
      version: _normalizeVersion(version),
      assetName: selected['name']?.toString() ?? 'AurumVPN-update.apk',
      downloadUrl: Uri.parse(downloadUrl),
      size: selected['size'] is int ? selected['size'] as int : null,
    );
  }

  Map<String, dynamic>? _selectAsset(
    List<Map<String, dynamic>> assets,
    List<String> supportedAbis,
  ) {
    final apks = assets
        .where((asset) {
          final name = asset['name']?.toString().toLowerCase() ?? '';
          return name.endsWith('.apk');
        })
        .toList(growable: false);
    if (apks.isEmpty) {
      return null;
    }

    final priorities = <String>[
      if (supportedAbis.contains('arm64-v8a')) 'arm64-v8a',
      if (supportedAbis.contains('armeabi-v7a')) 'armeabi-v7a',
      if (supportedAbis.contains('x86_64')) 'x86_64',
      'universal',
      'release',
    ];

    for (final priority in priorities) {
      for (final asset in apks) {
        final name = asset['name']?.toString().toLowerCase() ?? '';
        if (name.contains(priority)) {
          return asset;
        }
      }
    }

    return apks.first;
  }

  bool _isVersionNewer(String remote, String current) {
    final remoteParts = _versionParts(remote);
    final currentParts = _versionParts(current);
    final maxLength = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var i = 0; i < maxLength; i += 1) {
      final remotePart = i < remoteParts.length ? remoteParts[i] : 0;
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      if (remotePart != currentPart) {
        return remotePart > currentPart;
      }
    }
    return false;
  }

  List<int> _versionParts(String value) => _normalizeVersion(
    value,
  ).split('.').map((part) => int.tryParse(part) ?? 0).toList(growable: false);

  String _normalizeVersion(String value) {
    final match = RegExp(r'\d+(?:\.\d+)*').firstMatch(value);
    return match?.group(0) ?? value.replaceFirst(RegExp(r'^[vV]'), '');
  }
}
