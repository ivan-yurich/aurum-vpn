import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/app_update_service.dart';

void main() {
  test(
    'continues to next release endpoint when first release is stale',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        final stale = request.uri.path == '/stale';
        final payload = {
          'tag_name': stale ? 'v1.0.49' : 'v1.0.51',
          'assets': [
            {
              'name': 'YurichConnect-android-release.apk',
              'browser_download_url':
                  'http://127.0.0.1:${server.port}/download.apk',
              'size': 123,
            },
          ],
        };
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(payload));
        await request.response.close();
      });

      final service = AppUpdateService(
        releaseApiUris: [
          Uri.parse('http://127.0.0.1:${server.port}/stale'),
          Uri.parse('http://127.0.0.1:${server.port}/latest'),
        ],
      );

      final update = await service.findLatest(
        currentVersion: '1.0.50',
        supportedAbis: const ['arm64-v8a'],
      );

      expect(update, isNotNull);
      expect(update!.version, '1.0.51');
      expect(update.assetName, 'YurichConnect-android-release.apk');
    },
  );
}
