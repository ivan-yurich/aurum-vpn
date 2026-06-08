import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/vpn_profile.dart';

class ProfileStore {
  static const _profilesKey = 'profiles';
  static const _selectedProfileKey = 'selectedProfileId';
  static const _languageKey = 'languageCode';
  static const _autoConnectKey = 'autoConnect';
  static const _subscriptionReminderStampKey = 'subscriptionReminderStamp';
  static const _splitTunnelExcludedProcessesKey =
      'splitTunnelExcludedProcesses';

  Future<List<VpnProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_profilesKey);
    if (encoded == null || encoded.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(encoded) as List<dynamic>;
    return decoded
        .whereType<Map>()
        .map((json) => VpnProfile.fromJson(json.cast<String, dynamic>()))
        .toList();
  }

  Future<void> saveProfiles(List<VpnProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      profiles.map((profile) => profile.toJson()).toList(),
    );
    await prefs.setString(_profilesKey, encoded);
  }

  Future<String?> loadSelectedProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedProfileKey);
  }

  Future<void> saveSelectedProfileId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedProfileKey);
    } else {
      await prefs.setString(_selectedProfileKey, id);
    }
  }

  Future<String?> loadLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languageKey);
  }

  Future<void> saveLanguageCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, code);
  }

  Future<bool> loadAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoConnectKey) ?? false;
  }

  Future<void> saveAutoConnect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoConnectKey, enabled);
  }

  Future<String?> loadSubscriptionReminderStamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subscriptionReminderStampKey);
  }

  Future<void> saveSubscriptionReminderStamp(String stamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subscriptionReminderStampKey, stamp);
  }

  Future<List<String>> loadSplitTunnelExcludedProcesses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_splitTunnelExcludedProcessesKey) ?? const [];
  }

  Future<void> saveSplitTunnelExcludedProcesses(List<String> processes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_splitTunnelExcludedProcessesKey, processes);
  }
}
