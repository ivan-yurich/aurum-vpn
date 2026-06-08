import 'package:flutter_test/flutter_test.dart';
import 'package:aurum_vpn/src/services/profile_geo_service.dart';

void main() {
  test('converts ISO country code to flag emoji', () {
    expect(ProfileGeo.countryCodeToFlag('FI'), '🇫🇮');
    expect(ProfileGeo.countryCodeToFlag('ru'), '🇷🇺');
    expect(ProfileGeo.countryCodeToFlag('USA'), isNull);
    expect(ProfileGeo.countryCodeToFlag(''), isNull);
  });
}
