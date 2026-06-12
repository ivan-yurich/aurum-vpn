import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/protocol_display_mapper.dart';
import 'package:aurum_vpn/src/utils/traffic_formatter.dart';

void main() {
  group('TrafficFormatter', () {
    test('formats speeds and bytes', () {
      expect(TrafficFormatter.formatSpeed(0), '0 B/s');
      expect(TrafficFormatter.formatSpeed(512), '512 B/s');
      expect(TrafficFormatter.formatSpeed(2048), '2 KB/s');
      expect(TrafficFormatter.formatSpeed(1048576), '1 MB/s');
      expect(TrafficFormatter.formatBytes(128 * 1024 * 1024), '128 MB');
    });

    test('formats duration as hh:mm:ss', () {
      expect(
        TrafficFormatter.formatDuration(const Duration(seconds: 12)),
        '00:00:12',
      );
      expect(
        TrafficFormatter.formatDuration(
          const Duration(minutes: 12, seconds: 35),
        ),
        '00:12:35',
      );
      expect(
        TrafficFormatter.formatDuration(
          const Duration(hours: 1, minutes: 5, seconds: 10),
        ),
        '01:05:10',
      );
    });
  });

  group('ProtocolDisplayMapper', () {
    test('maps public protocol names', () {
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName(
          'vless',
          transport: 'tcp',
          security: 'reality',
        ),
        'Xray REALITY TCP / Стабильный',
      );
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName(
          'vless',
          transport: 'xhttp',
          security: 'reality',
        ),
        'Xray REALITY XHTTP / Современный',
      );
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName('naiveproxy'),
        'Yurich Proxy Naive / Быстрый',
      );
      expect(
        ProtocolDisplayMapper.mapProtocolToDisplayName('hy2'),
        'Hysteria 2 / Турбо',
      );
    });
  });
}
