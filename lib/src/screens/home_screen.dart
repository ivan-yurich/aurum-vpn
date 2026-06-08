import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/vpn_profile.dart';
import '../services/app_update_service.dart';
import '../services/profile_geo_service.dart';
import '../services/profile_importer.dart';
import '../services/profile_store.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import 'qr_scan_screen.dart';

const _gold = Color(0xFF0EA5FF);
const _goldSoft = Color(0xFFEAF7FF);
const _danger = Color(0xFFFF3B5C);
const _dangerSoft = Color(0xFFFFD7DF);
const _ink = Color(0xFF06111C);
const _surface = Color(0xFF0D1A27);
const _surfaceMetric = Color(0xFF10283B);
const _mutedGold = Color(0xFF8EA9BD);
const _appName = 'Yurich Connect';
const _telegramUrl = 'https://t.me/ivan_it_net';
const _vkUrl = 'https://vk.com/ivan_yurievich_it';
const _donateUrl = 'https://dzen.ru/ivanyurievich?donate=true';
const _supportEmail = 'ai@ivan-it.net';
const _appVersion = '1.0.44';
const _nativeShortTimeout = Duration(seconds: 3);
const _nativeConfigTimeout = Duration(seconds: 5);
const _nativeStartTimeout = Duration(seconds: 8);
const _subscriptionReminderWindow = Duration(days: 5);
const _tunnelHealthProbeInterval = Duration(seconds: 105);
const _startupProbeRecheckDelay = Duration(seconds: 8);
const _recentTrafficGrace = Duration(seconds: 120);
const _tunnelHealthFailureThreshold = 4;
const _autoReconnectMaxAttempts = 6;
const _maxStoredLogs = 180;
const _maxPendingLogs = 240;

class _ConnectionConfigPlan {
  const _ConnectionConfigPlan(this.naiveMode, this.label);

  final NaiveOutboundMode naiveMode;
  final String label;
}

enum _AppLanguage {
  ru('ru'),
  en('en');

  const _AppLanguage(this.code);

  final String code;

  static _AppLanguage fromCode(String? code) {
    return values.firstWhere(
      (language) => language.code == code,
      orElse: () => _AppLanguage.ru,
    );
  }
}

enum _ProfileTab { all, vless, naive, hysteria, singBox }

enum _SupportTab { help, community }

_ProfileTab _profileTabForKind(VpnProfileKind kind) {
  return switch (kind) {
    VpnProfileKind.vlessReality || VpnProfileKind.vlessTls => _ProfileTab.vless,
    VpnProfileKind.naive => _ProfileTab.naive,
    VpnProfileKind.hysteria2 || VpnProfileKind.hysteria => _ProfileTab.hysteria,
    VpnProfileKind.singBoxConfig => _ProfileTab.singBox,
  };
}

bool _profileMatchesTab(VpnProfile profile, _ProfileTab tab) {
  return tab == _ProfileTab.all || _profileTabForKind(profile.kind) == tab;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _vpnEngine = createVpnEngine();
  final _store = ProfileStore();
  final _importer = ProfileImporter();
  final _configBuilder = SingBoxConfigBuilder();
  final _updateService = AppUpdateService();
  final _geoService = ProfileGeoService();
  final _manualController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _statusSubscription;
  StreamSubscription<Map<String, dynamic>>? _trafficSubscription;
  StreamSubscription<Map<String, dynamic>>? _logSubscription;
  Timer? _logFlushTimer;
  Timer? _trafficFlushTimer;
  Timer? _statusWatchdogTimer;
  Timer? _uptimeTimer;
  Timer? _subscriptionReminderTimer;
  DateTime? _ignoreStoppedUntil;
  DateTime? _connectedSince;
  DateTime? _lastTrafficAt;
  DateTime? _lastHealthyAt;
  DateTime _clockNow = DateTime.now();
  Map<String, dynamic>? _latestTrafficEvent;

  List<VpnProfile> _profiles = const [];
  final _profilePingMs = <String, int>{};
  final _profilePingText = <String, String>{};
  final _profilePingBusy = <String, bool>{};
  final _profilePingError = <String, String>{};
  String? _selectedProfileId;
  _AppLanguage _language = _AppLanguage.ru;
  _ProfileTab _profileTab = _ProfileTab.all;
  _SupportTab _supportTab = _SupportTab.help;
  String _status = AurumVpnStatus.stopped;
  String _uplink = '0 B/s';
  String _downlink = '0 B/s';
  String _sessionTotal = '0 B';
  String _message = 'Готов к импорту подписки';
  String? _lastError;
  bool _busy = false;
  bool _updateBusy = false;
  bool _subscriptionRefreshBusy = false;
  bool _stoppingByUser = false;
  bool _statusWatchdogInFlight = false;
  bool _tunnelHealthCheckInFlight = false;
  bool _autoReconnectInFlight = false;
  bool _autoRecoveryArmed = false;
  bool _pingAllInFlight = false;
  bool _countryResolveInFlight = false;
  bool _logsExpanded = false;
  String? _lastConfigSummary;
  String? _updateMessage;
  double? _updateProgress;
  DateTime? _nextAutoReconnectAt;
  DateTime? _nextTunnelHealthCheckAt;
  int _autoReconnectAttempts = 0;
  int _tunnelHealthFailures = 0;
  int _lastSessionTrafficBytes = 0;
  final _logs = <String>[];
  final _pendingLogs = <String>[];

  _Strings get s => _Strings.forLanguage(_language);

  Duration? get _connectedDuration {
    final since = _connectedSince;
    if (since == null || _status != AurumVpnStatus.started) {
      return null;
    }
    final duration = _clockNow.difference(since);
    return duration.isNegative ? Duration.zero : duration;
  }

  VpnProfile? get _selectedProfile {
    for (final profile in _profiles) {
      if (profile.id == _selectedProfileId) {
        return profile;
      }
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  bool get _connected =>
      _status == AurumVpnStatus.started || _status == AurumVpnStatus.starting;

  bool get _connectionDegraded {
    if (_stoppingByUser) {
      return false;
    }
    if (_autoReconnectInFlight || _tunnelHealthFailures > 0) {
      return true;
    }
    if (_autoRecoveryArmed && _lastError != null && _lastError!.isNotEmpty) {
      return true;
    }
    if (_autoRecoveryArmed && _status == AurumVpnStatus.stopped) {
      return true;
    }
    if (_status == AurumVpnStatus.started) {
      final lastHealthyAt = _lastHealthyAt;
      if (lastHealthyAt != null &&
          DateTime.now().difference(lastHealthyAt) >
              const Duration(minutes: 4)) {
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _initVpn();
    _statusWatchdogTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_refreshStatusWatchdog()),
    );
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _status != AurumVpnStatus.started) {
        return;
      }
      setState(() => _clockNow = DateTime.now());
    });
    _subscriptionReminderTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(_showSubscriptionRenewalReminder(_profiles)),
    );
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _trafficSubscription?.cancel();
    _logSubscription?.cancel();
    _logFlushTimer?.cancel();
    _trafficFlushTimer?.cancel();
    _statusWatchdogTimer?.cancel();
    _uptimeTimer?.cancel();
    _subscriptionReminderTimer?.cancel();
    _manualController.dispose();
    unawaited(_vpnEngine.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    final profiles = await _store.loadProfiles();
    final selectedId = await _store.loadSelectedProfileId();
    final language = _AppLanguage.fromCode(await _store.loadLanguageCode());
    if (!mounted) {
      return;
    }
    final strings = _Strings.forLanguage(language);
    final resolvedSelectedId =
        profiles.any((profile) => profile.id == selectedId)
        ? selectedId
        : (profiles.isEmpty ? null : profiles.first.id);
    setState(() {
      _language = language;
      _profiles = profiles;
      _selectedProfileId = resolvedSelectedId;
      _message = profiles.isEmpty
          ? strings.addProfileHint
          : strings.loadedProfiles(profiles.length);
    });
    unawaited(_pingProfiles(profiles));
    unawaited(_resolveProfileCountries(profiles));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_showSubscriptionRenewalReminder(profiles));
      }
    });
  }

  Future<void> _initVpn() async {
    _statusSubscription = _vpnEngine.onStatusChanged.listen((event) {
      if (event['type'] == 'alert') {
        final message = event['message'] as String?;
        if (message != null && message.isNotEmpty && mounted) {
          setState(() => _message = message);
          _showSnack(message);
        }
        return;
      }

      final status = event['status'] as String?;
      if (status != null && mounted) {
        final now = DateTime.now();
        var recoverUnexpectedStop = false;
        setState(() {
          _status = status;
          if (status == AurumVpnStatus.started) {
            _lastError = null;
            _autoReconnectAttempts = 0;
            _nextAutoReconnectAt = null;
            _autoRecoveryArmed = true;
            _connectedSince ??= now;
            _lastHealthyAt = now;
            _lastTrafficAt ??= now;
            _clockNow = now;
            _ignoreStoppedUntil = now.add(const Duration(seconds: 4));
          }
          if (status == AurumVpnStatus.stopped && !_autoRecoveryArmed) {
            _connectedSince = null;
            _lastTrafficAt = null;
            _lastHealthyAt = null;
          }
          final ignoreStopped =
              _ignoreStoppedUntil != null && now.isBefore(_ignoreStoppedUntil!);
          if (status == AurumVpnStatus.stopped &&
              _autoRecoveryArmed &&
              !_stoppingByUser &&
              !ignoreStopped) {
            recoverUnexpectedStop = true;
          }
        });
        if (recoverUnexpectedStop) {
          _markUnexpectedStop('status-event');
        }
      }
    });

    _trafficSubscription = _vpnEngine.onTrafficUpdate.listen((event) {
      if (!mounted) {
        return;
      }
      _latestTrafficEvent = event;
      _trafficFlushTimer ??= Timer(const Duration(milliseconds: 500), () {
        _trafficFlushTimer = null;
        final latest = _latestTrafficEvent;
        _latestTrafficEvent = null;
        if (!mounted || latest == null) {
          return;
        }
        final uplinkSpeed = _eventInt(latest['uplinkSpeed']);
        final downlinkSpeed = _eventInt(latest['downlinkSpeed']);
        final sessionTotal = _eventInt(latest['sessionTotal']);
        final hasTraffic =
            uplinkSpeed > 0 ||
            downlinkSpeed > 0 ||
            sessionTotal > _lastSessionTrafficBytes;
        final now = DateTime.now();
        setState(() {
          _uplink = latest['formattedUplinkSpeed'] as String? ?? _uplink;
          _downlink = latest['formattedDownlinkSpeed'] as String? ?? _downlink;
          _sessionTotal =
              latest['formattedSessionTotal'] as String? ?? _sessionTotal;
          if (sessionTotal >= _lastSessionTrafficBytes) {
            _lastSessionTrafficBytes = sessionTotal;
          }
          if (hasTraffic && _status == AurumVpnStatus.started) {
            _lastTrafficAt = now;
            _lastHealthyAt = now;
            _tunnelHealthFailures = 0;
          }
        });
      });
    });

    try {
      await _bestEffortNative(
        'setNotificationTitle',
        _vpnEngine.setNotificationTitle(_appName),
      );
      await _bestEffortNative(
        'setNotificationDescription',
        _vpnEngine.setNotificationDescription(s.notificationDescription),
      );
      await _bestEffortNative(
        'requestNotificationPermission',
        _vpnEngine.requestNotificationPermission(),
      );
      final status = await _vpnEngine.getVPNStatus().timeout(
        _nativeShortTimeout,
        onTimeout: () => _status,
      );
      final bufferedLogs = await _vpnEngine.getLogs().timeout(
        const Duration(seconds: 2),
        onTimeout: () => const <String>[],
      );
      if (mounted) {
        setState(() {
          _status = status;
          if (status == AurumVpnStatus.started) {
            _autoRecoveryArmed = true;
            _connectedSince ??= DateTime.now();
            _clockNow = DateTime.now();
          } else if (status == AurumVpnStatus.stopped) {
            _autoRecoveryArmed = false;
            _connectedSince = null;
          }
          _logs
            ..clear()
            ..addAll(
              bufferedLogs
                  .map(_cleanLog)
                  .where((log) => log.isNotEmpty)
                  .toList()
                  .reversed
                  .take(_maxStoredLogs)
                  .toList()
                  .reversed,
            );
        });
      }
    } on Object {
      // In widget tests and desktop preview the native Android plugin is absent.
    }
  }

  Future<void> _importManual() async {
    await _importText(_manualController.text);
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    await _importText(text);
  }

  Future<void> _importFromQr() async {
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (value == null || value.trim().isEmpty) {
      return;
    }
    await _importText(value);
  }

  Future<void> _showImportSheet() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(18, 24, 18, 24 + bottomInset),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Material(
                color: _surface,
                elevation: 18,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.addProfile,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: s.close,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _manualController,
                        minLines: 3,
                        maxLines: 6,
                        decoration: InputDecoration(hintText: s.importHint),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    unawaited(_importManual());
                                  },
                            icon: const Icon(Icons.add_link),
                            label: Text(s.importAction),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    unawaited(_importFromClipboard());
                                  },
                            icon: const Icon(Icons.content_paste),
                            label: Text(s.clipboard),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    unawaited(_importFromQr());
                                  },
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('QR'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _importText(String text) async {
    await _runBusy(() async {
      final imported = await _importer.importFromText(text);
      if (imported.isEmpty) {
        throw ProfileImportException(s.nothingToImport);
      }

      final importedWithCachedData = _profilesWithCachedData(imported);
      final merged = _mergeProfiles(importedWithCachedData);

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(importedWithCachedData.first.id);
      _manualController.clear();

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = merged;
        _selectedProfileId = importedWithCachedData.first.id;
        _profileTab = _profileTabForKind(importedWithCachedData.first.kind);
        _message = s.imported(imported.length);
      });
      unawaited(_pingProfiles(merged));
      unawaited(_resolveProfileCountries(merged));
      unawaited(_showSubscriptionRenewalReminder(merged, force: true));
      _showSnack(s.importedProfiles(imported.length));
    });
  }

  List<VpnProfile> _profilesWithCachedData(List<VpnProfile> profiles) {
    final existingById = {for (final profile in _profiles) profile.id: profile};

    return profiles
        .map((profile) {
          final existing = existingById[profile.id];
          if (existing == null) {
            return profile;
          }
          return profile.copyWith(
            subscriptionExpiresAt:
                profile.subscriptionExpiresAt ?? existing.subscriptionExpiresAt,
            subscriptionSource:
                profile.subscriptionSource ?? existing.subscriptionSource,
            countryCode: profile.countryCode ?? existing.countryCode,
            countryName: profile.countryName ?? existing.countryName,
          );
        })
        .toList(growable: false);
  }

  List<VpnProfile> _mergeProfiles(List<VpnProfile> profiles) {
    return <String, VpnProfile>{
      for (final profile in _profiles) profile.id: profile,
      for (final profile in profiles) profile.id: profile,
    }.values.toList();
  }

  List<String> _subscriptionSourcesFor(List<VpnProfile> profiles) {
    final sources = <String>{};
    for (final profile in profiles) {
      final source = (profile.subscriptionSource ?? profile.originalInput)
          .trim();
      final uri = Uri.tryParse(source);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        sources.add(source);
      }
    }
    return sources.toList(growable: false);
  }

  Future<void> _refreshSubscriptions() async {
    if (_busy || _subscriptionRefreshBusy) {
      return;
    }

    final sources = _subscriptionSourcesFor(_profiles);
    if (sources.isEmpty) {
      _showSnack(s.noSubscriptionsToRefresh);
      unawaited(_showImportSheet());
      return;
    }

    setState(() {
      _subscriptionRefreshBusy = true;
      _message = s.refreshingSubscriptions;
    });

    try {
      final imported = <VpnProfile>[];
      Object? lastError;
      for (final source in sources) {
        try {
          imported.addAll(await _importer.importFromText(source));
        } on Object catch (error) {
          lastError = error;
          _queueLog(
            'Subscription refresh failed: ${_redactSensitive(source)} | '
            '${_redactSensitive('$error')}',
          );
        }
      }

      if (imported.isEmpty) {
        throw ProfileImportException(
          s.subscriptionRefreshFailed(
            _redactSensitive('${lastError ?? s.nothingToImport}'),
          ),
        );
      }

      final importedWithCachedData = _profilesWithCachedData(imported);
      final merged = _mergeProfiles(importedWithCachedData);
      final selectedId =
          _selectedProfileId != null &&
              merged.any((profile) => profile.id == _selectedProfileId)
          ? _selectedProfileId
          : (merged.isEmpty ? null : merged.first.id);

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(selectedId);
      if (!mounted) {
        return;
      }

      setState(() {
        _profiles = merged;
        _selectedProfileId = selectedId;
        _message = s.subscriptionsUpdated(importedWithCachedData.length);
      });
      unawaited(_pingProfiles(merged));
      unawaited(_resolveProfileCountries(merged));
      unawaited(_showSubscriptionRenewalReminder(merged, force: true));
      _showSnack(s.subscriptionsUpdated(importedWithCachedData.length));
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
        _showSnack(errorText);
      }
    } finally {
      if (mounted) {
        setState(() => _subscriptionRefreshBusy = false);
      }
    }
  }

  bool _subscriptionNeedsAttention(VpnProfile profile) {
    final expiresAt = profile.subscriptionExpiresAt;
    if (expiresAt == null) {
      return false;
    }

    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    return remaining <= _subscriptionReminderWindow;
  }

  String? _subscriptionTileStatus(VpnProfile profile) {
    if (profile.subscriptionExpiresAt == null) {
      return null;
    }
    return s.subscriptionStatus(profile.subscriptionExpiresAt);
  }

  List<VpnProfile> _subscriptionReminderProfiles(List<VpnProfile> profiles) {
    final warnedBySource = <String>{};
    final due = <VpnProfile>[];
    for (final profile in profiles) {
      if (!_subscriptionNeedsAttention(profile)) {
        continue;
      }

      final source = (profile.subscriptionSource ?? profile.originalInput)
          .trim();
      final sourceKey = source.isNotEmpty ? source : profile.id;
      if (!warnedBySource.add(sourceKey)) {
        continue;
      }
      due.add(profile);
    }

    due.sort((a, b) {
      final left =
          a.subscriptionExpiresAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right =
          b.subscriptionExpiresAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return left.compareTo(right);
    });
    return due;
  }

  Future<void> _showSubscriptionRenewalReminder(
    List<VpnProfile> profiles, {
    bool force = false,
  }) async {
    if (!mounted || profiles.isEmpty) {
      return;
    }

    final due = _subscriptionReminderProfiles(profiles);
    if (due.isEmpty) {
      return;
    }

    final primary = due.first;
    final expiresAt = primary.subscriptionExpiresAt;
    if (expiresAt == null) {
      return;
    }

    final localDay = DateTime.now()
        .toLocal()
        .toIso8601String()
        .split('T')
        .first;
    final stamp =
        '$localDay|${primary.subscriptionSource ?? (primary.originalInput.isEmpty ? primary.id : primary.originalInput)}|${expiresAt.toUtc().toIso8601String()}';
    if (!force && await _store.loadSubscriptionReminderStamp() == stamp) {
      return;
    }

    final profileName = _profileDisplayName(primary);
    final status = s.subscriptionStatus(expiresAt);
    final body = due.length == 1
        ? s.subscriptionReminderBody(profileName, status)
        : s.subscriptionReminderMany(due.length, profileName, status);

    await _store.saveSubscriptionReminderStamp(stamp);
    _showSnack(body);

    try {
      await _vpnEngine.requestNotificationPermission().timeout(
        _nativeShortTimeout,
      );
      final shown = await _vpnEngine
          .showAppNotification(
            title: s.subscriptionReminderTitle,
            body: body,
            id: 7039,
          )
          .timeout(_nativeShortTimeout);
      if (!shown) {
        _queueLog('Subscription reminder notification skipped: permission');
      }
    } on Object catch (error) {
      _queueLog(
        'Subscription reminder notification failed: '
        '${_redactSensitive('$error')}',
      );
    }
  }

  Future<void> _toggleVpn() async {
    if (_connected) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _selectProfile(VpnProfile profile) async {
    if (_busy) {
      return;
    }

    final current = _selectedProfile;
    if (current?.id == profile.id) {
      return;
    }

    if (!_connected) {
      setState(() {
        _selectedProfileId = profile.id;
        _message = s.selectedProfile(profile.name);
      });
      await _store.saveSelectedProfileId(profile.id);
      unawaited(_pingProfile(profile));
      return;
    }

    await _runBusy(() async {
      await _stopVpnCore(updateMessage: false);
      await _startVpnCore(profile);
    }, message: s.switchingProfile);
  }

  Future<void> _connect() async {
    final profile = _selectedProfile;
    if (profile == null) {
      _showSnack(s.importFirst);
      return;
    }

    _autoRecoveryArmed = true;
    await _runBusy(() async {
      try {
        await _startVpnCore(profile);
      } on Object {
        _autoRecoveryArmed = false;
        rethrow;
      }
    }, message: s.connectingTo(profile.name));
  }

  Future<void> _startVpnCore(VpnProfile profile) async {
    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    final status = await _refreshVpnStatus();
    if (status != AurumVpnStatus.stopped) {
      await _stopVpnCore(updateMessage: false);
    }

    await Future<void>.delayed(const Duration(milliseconds: 1400));

    _pendingLogs.clear();
    _logs.clear();
    _lastError = null;
    _lastTrafficAt = null;
    _lastHealthyAt = null;
    _lastSessionTrafficBytes = 0;
    _tunnelHealthFailures = 0;
    await _bestEffortNative('clearLogs', _vpnEngine.clearLogs());

    await _bestEffortNative(
      'requestNotificationPermission',
      _vpnEngine.requestNotificationPermission(),
    );

    Object? lastStartError;
    var connected = false;
    var startupProbeDegraded = false;
    final plans = _connectionPlans(profile);

    for (
      var planIndex = 0;
      planIndex < plans.length && !connected;
      planIndex += 1
    ) {
      final plan = plans[planIndex];
      final config = _configBuilder.build(profile, naiveMode: plan.naiveMode);
      final configSummary = _summarizeSingBoxConfig(
        config,
        target: _vpnEngine.configTarget,
      );
      final saved = await _nativeCall(
        'saveConfig',
        _vpnEngine.saveConfig(config),
        timeout: _nativeConfigTimeout,
      );
      if (!saved) {
        throw StateError(s.configSaveFailed);
      }

      for (var attempt = 1; attempt <= 2 && !connected; attempt += 1) {
        if (mounted) {
          setState(() {
            _selectedProfileId = profile.id;
            _lastError = null;
            _message = plans.length > 1
                ? '${s.connectingStatus(profile.name)} · ${plan.label}'
                : s.connectingStatus(profile.name);
            _uplink = '0 B/s';
            _downlink = '0 B/s';
            _sessionTotal = '0 B';
            _lastConfigSummary = configSummary;
          });
        }

        bool started;
        try {
          started = await _nativeCall(
            'startVPN',
            _vpnEngine.startVPN(),
            timeout: _nativeStartTimeout,
          );
        } on Object catch (error) {
          started = false;
          lastStartError = _redactSensitive('$error');
        }
        if (started) {
          final finalStatus = await _waitForVpnStatus({
            AurumVpnStatus.started,
          }, timeout: const Duration(seconds: 14));
          if (finalStatus == AurumVpnStatus.started) {
            if (profile.kind != VpnProfileKind.naive) {
              connected = true;
              break;
            }

            if (await _probeLocalMixedProxy()) {
              connected = true;
              break;
            } else {
              startupProbeDegraded = true;
              connected = true;
              _queueLog(
                'Naive startup probe did not pass after VPN status Started; '
                'keeping tunnel alive and handing off to watchdog.',
              );
              break;
            }
          } else {
            lastStartError = s.vpnNotConnected(finalStatus);
          }
        } else {
          lastStartError = s.vpnStartFailed;
        }

        if (!connected) {
          _queueLog(
            'VPN start retry [$attempt/${plan.label}]: '
            '${_redactSensitive('$lastStartError')}',
          );
          await _stopVpnCore(updateMessage: false);
          await Future<void>.delayed(const Duration(milliseconds: 1600));
          await _bestEffortNative(
            'saveConfig retry',
            _vpnEngine.saveConfig(config),
            timeout: _nativeConfigTimeout,
          );
          _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 14));
        }
      }

      if (!connected && planIndex < plans.length - 1) {
        _queueLog('Naive mode fallback: ${plan.label} did not pass probe.');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }

    if (!connected) {
      throw StateError('${lastStartError ?? s.vpnStartFailed}');
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _store.saveSelectedProfileId(profile.id);
    if (mounted) {
      setState(() {
        _selectedProfileId = profile.id;
        _lastError = null;
        _autoReconnectAttempts = 0;
        _nextAutoReconnectAt = null;
        _tunnelHealthFailures = startupProbeDegraded
            ? _tunnelHealthFailureThreshold - 1
            : 0;
        _autoRecoveryArmed = true;
        _connectedSince ??= DateTime.now();
        _clockNow = DateTime.now();
        _lastTrafficAt = DateTime.now();
        _lastHealthyAt = startupProbeDegraded ? null : DateTime.now();
        _lastSessionTrafficBytes = 0;
        _nextTunnelHealthCheckAt = DateTime.now().add(
          startupProbeDegraded
              ? _startupProbeRecheckDelay
              : _tunnelHealthProbeInterval,
        );
        _message = s.connectionProfile(profile.name);
      });
    }
    unawaited(_refreshConnectedCountry(profile.id));
  }

  Future<void> _disconnect() async {
    _autoRecoveryArmed = false;
    await _runBusy(() => _stopVpnCore(), message: s.disconnectingVpn);
  }

  Future<void> _stopVpnCore({bool updateMessage = true}) async {
    _stoppingByUser = true;
    _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
    if (mounted) {
      setState(() => _lastError = null);
    }
    try {
      final status = await _refreshVpnStatus();
      if (status != AurumVpnStatus.stopped) {
        await _vpnEngine.stopVPN().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _queueLog('Native call timeout [stopVPN]');
            return true;
          },
        );
        final stoppedStatus = await _waitForVpnStatus({
          AurumVpnStatus.stopped,
        }, timeout: const Duration(seconds: 7));
        if (stoppedStatus != AurumVpnStatus.stopped) {
          _queueLog('VPN stop cleanup is still finishing: $stoppedStatus');
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      if (mounted) {
        _ignoreStoppedUntil = DateTime.now().add(const Duration(seconds: 18));
        setState(() {
          _status = AurumVpnStatus.stopped;
          _uplink = '0 B/s';
          _downlink = '0 B/s';
          if (updateMessage) {
            _autoRecoveryArmed = false;
            _connectedSince = null;
            _lastTrafficAt = null;
            _lastHealthyAt = null;
            _lastSessionTrafficBytes = 0;
            _tunnelHealthFailures = 0;
          }
          _lastError = null;
          if (updateMessage) {
            _message = s.vpnStopped;
          }
        });
      }
    } finally {
      _stoppingByUser = false;
    }
  }

  Future<String> _refreshVpnStatus() async {
    try {
      final status = await _nativeCall(
        'getVPNStatus',
        _vpnEngine.getVPNStatus(),
        timeout: _nativeShortTimeout,
      );
      if (mounted) {
        setState(() => _status = status);
      }
      return status;
    } on Object {
      return _status;
    }
  }

  Future<String> _waitForVpnStatus(
    Set<String> expected, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var latest = _status;
    while (DateTime.now().isBefore(deadline)) {
      latest = await _refreshVpnStatus();
      if (expected.contains(latest)) {
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return latest;
  }

  Future<void> _refreshStatusWatchdog() async {
    if (!mounted || _busy || _statusWatchdogInFlight) {
      return;
    }

    _statusWatchdogInFlight = true;
    try {
      final previous = _status;
      final status = await _refreshVpnStatus();
      final ignoreStopped =
          _ignoreStoppedUntil != null &&
          DateTime.now().isBefore(_ignoreStoppedUntil!);
      if (previous == AurumVpnStatus.started &&
          status == AurumVpnStatus.stopped &&
          _autoRecoveryArmed &&
          !_stoppingByUser &&
          !ignoreStopped &&
          mounted) {
        _markUnexpectedStop('watchdog');
      } else if (status == AurumVpnStatus.started &&
          _autoRecoveryArmed &&
          !_stoppingByUser &&
          !ignoreStopped) {
        await _refreshTunnelHealth();
      }
    } finally {
      _statusWatchdogInFlight = false;
    }
  }

  void _markUnexpectedStop(String source) {
    if (!mounted || _stoppingByUser || !_autoRecoveryArmed) {
      return;
    }

    final profile = _selectedProfile;
    _queueLog('VPN watchdog: unexpected stop detected from $source.');
    setState(() {
      _lastError = s.vpnStoppedUnexpectedly;
      _message = profile == null
          ? s.openLogsMessage
          : '${s.vpnStoppedUnexpectedly}. ${s.connectingStatus(profile.name)}';
    });
    unawaited(_recoverUnexpectedStop(source));
  }

  Future<void> _refreshTunnelHealth() async {
    if (_autoReconnectInFlight || _tunnelHealthCheckInFlight || !mounted) {
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      return;
    }

    final now = DateTime.now();
    final nextCheckAt = _nextTunnelHealthCheckAt;
    if (nextCheckAt != null && now.isBefore(nextCheckAt)) {
      return;
    }

    final lastTrafficAt = _lastTrafficAt;
    if (lastTrafficAt != null &&
        now.difference(lastTrafficAt) < _recentTrafficGrace) {
      _tunnelHealthFailures = 0;
      _lastHealthyAt = lastTrafficAt;
      _nextTunnelHealthCheckAt = now.add(_tunnelHealthProbeInterval);
      return;
    }

    _nextTunnelHealthCheckAt = now.add(_tunnelHealthProbeInterval);
    _tunnelHealthCheckInFlight = true;
    try {
      final healthy = await _probeLocalMixedProxy(
        attempts: 1,
        logFailures: false,
      );
      if (!mounted || _status != AurumVpnStatus.started) {
        return;
      }

      if (healthy) {
        _tunnelHealthFailures = 0;
        _lastHealthyAt = DateTime.now();
        return;
      }

      _tunnelHealthFailures += 1;
      _queueLog(
        'VPN watchdog: health probe failed #$_tunnelHealthFailures '
        'for ${profile.name}.',
      );

      if (_tunnelHealthFailures >= _tunnelHealthFailureThreshold) {
        _tunnelHealthFailures = 0;
        _queueLog(
          'VPN watchdog: tunnel is unhealthy, reconnecting ${profile.name}.',
        );
        if (mounted) {
          setState(() {
            _lastError = null;
            _message = s.connectingStatus(profile.name);
          });
        }
        unawaited(_recoverConnection('health-probe', forceRestart: true));
      }
    } finally {
      _tunnelHealthCheckInFlight = false;
    }
  }

  Future<void> _recoverUnexpectedStop(String source) {
    return _recoverConnection(source, forceRestart: false);
  }

  Future<void> _recoverConnection(
    String source, {
    required bool forceRestart,
  }) async {
    if (_autoReconnectInFlight || _busy || _stoppingByUser || !mounted) {
      return;
    }

    final profile = _selectedProfile;
    if (profile == null) {
      return;
    }

    final now = DateTime.now();
    final nextAttemptAt = _nextAutoReconnectAt;
    if (nextAttemptAt != null && now.isBefore(nextAttemptAt)) {
      return;
    }

    if (_autoReconnectAttempts >= _autoReconnectMaxAttempts) {
      _nextAutoReconnectAt = now.add(const Duration(minutes: 5));
      _queueLog(
        'VPN watchdog: auto reconnect paused for mobile network cooldown.',
      );
      if (mounted) {
        setState(() {
          _message = s.networkRecoveryPaused(profile.name);
        });
      }
      return;
    }

    _autoReconnectInFlight = true;
    _autoReconnectAttempts += 1;
    if (mounted) {
      setState(() => _busy = true);
    }
    final attempt = _autoReconnectAttempts;
    final delay = attempt == 1
        ? const Duration(milliseconds: 900)
        : attempt == 2
        ? const Duration(seconds: 4)
        : attempt == 3
        ? const Duration(seconds: 10)
        : const Duration(seconds: 20);
    final cooldown = attempt <= 2
        ? const Duration(seconds: 25)
        : attempt <= 4
        ? const Duration(seconds: 60)
        : const Duration(seconds: 120);
    _nextAutoReconnectAt = now.add(cooldown);

    _queueLog(
      'VPN watchdog: auto reconnect #$attempt from $source for ${profile.name}.',
    );

    try {
      await Future<void>.delayed(delay);
      if (!mounted || _stoppingByUser) {
        return;
      }

      final status = await _refreshVpnStatus();
      if (!forceRestart && status != AurumVpnStatus.stopped) {
        _autoReconnectAttempts = 0;
        _nextAutoReconnectAt = null;
        return;
      }

      if (mounted) {
        setState(() {
          _lastError = null;
          _message = s.connectingStatus(profile.name);
        });
      }

      if (forceRestart && status != AurumVpnStatus.stopped) {
        await _stopVpnCore(updateMessage: false);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }

      await _startVpnCore(profile);
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      _queueLog('VPN watchdog reconnect failed: $errorText');
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
      }
    } finally {
      _autoReconnectInFlight = false;
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  List<_ConnectionConfigPlan> _connectionPlans(VpnProfile profile) {
    if (profile.kind != VpnProfileKind.naive) {
      return const [_ConnectionConfigPlan(NaiveOutboundMode.auto, 'auto')];
    }

    final outboundType = (profile.outbound?['type'] as String?)?.toLowerCase();
    if (outboundType == 'http') {
      return const [
        _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
        _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
      ];
    }

    return const [
      _ConnectionConfigPlan(NaiveOutboundMode.httpConnect, 'https-connect'),
      _ConnectionConfigPlan(NaiveOutboundMode.native, 'native-naive'),
    ];
  }

  Future<bool> _probeLocalMixedProxy({
    int attempts = 2,
    bool logFailures = true,
  }) async {
    final endpoints = <({Uri uri, bool allowCertificateMismatch})>[
      (
        uri: Uri.https('cp.cloudflare.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
      (
        uri: Uri.https('www.gstatic.com', '/generate_204'),
        allowCertificateMismatch: false,
      ),
      // Some Naive servers have broken resolver settings but still proxy IP
      // targets correctly. This probe keeps startup from rejecting such
      // profiles while server-side DNS is being repaired.
      (uri: Uri.https('1.1.1.1', '/'), allowCertificateMismatch: true),
    ];

    for (var attempt = 1; attempt <= attempts; attempt += 1) {
      for (final endpoint in endpoints) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..badCertificateCallback = endpoint.allowCertificateMismatch
              ? (_, host, _) => host == endpoint.uri.host
              : null
          ..findProxy = (_) =>
              'PROXY 127.0.0.1:${SingBoxConfigBuilder.localMixedProxyPort}';
        try {
          final request = await client
              .getUrl(endpoint.uri)
              .timeout(const Duration(seconds: 5));
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'YurichConnect/$_appVersion',
          );
          request.followRedirects = false;
          final response = await request.close().timeout(
            const Duration(seconds: 7),
          );
          await response.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          if (response.statusCode >= 200 && response.statusCode < 400) {
            return true;
          }
          if (logFailures) {
            _queueLog(
              'VPN health probe HTTP ${response.statusCode}: ${endpoint.uri}',
            );
          }
        } on Object catch (error) {
          if (logFailures) {
            _queueLog('VPN health probe failed: ${_redactSensitive('$error')}');
          }
        } finally {
          client.close(force: true);
        }
      }

      if (attempt < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }

    return false;
  }

  Future<void> _pingProfiles(List<VpnProfile> profiles) async {
    if (_pingAllInFlight || profiles.isEmpty) {
      return;
    }

    _pingAllInFlight = true;
    try {
      for (final profile in profiles.take(16)) {
        if (!mounted) {
          return;
        }
        await _pingProfile(profile);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      _pingAllInFlight = false;
    }
  }

  Future<void> _pingProfile(VpnProfile profile) async {
    final server = profile.server?.trim();
    final port = profile.port ?? 443;
    if (server == null || server.isEmpty || port <= 0) {
      return;
    }
    if (_profilePingBusy[profile.id] == true) {
      return;
    }

    if (mounted) {
      setState(() {
        _profilePingBusy[profile.id] = true;
        _profilePingError.remove(profile.id);
      });
    }

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      if (_usesUdpEndpoint(profile)) {
        final addresses = await InternetAddress.lookup(
          server,
        ).timeout(const Duration(seconds: 4));
        if (addresses.isEmpty) {
          throw const SocketException('DNS lookup returned no addresses');
        }
        stopwatch.stop();
        if (!mounted) {
          return;
        }
        setState(() {
          _profilePingMs.remove(profile.id);
          _profilePingText[profile.id] = stopwatch.elapsedMilliseconds <= 1
              ? 'UDP ok'
              : 'DNS ${stopwatch.elapsedMilliseconds} ms';
          _profilePingError.remove(profile.id);
        });
        return;
      }

      socket = await Socket.connect(
        server,
        port,
        timeout: const Duration(seconds: 4),
      );
      stopwatch.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _profilePingMs[profile.id] = stopwatch.elapsedMilliseconds;
        _profilePingText.remove(profile.id);
        _profilePingError.remove(profile.id);
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _profilePingMs.remove(profile.id);
        _profilePingText.remove(profile.id);
        _profilePingError[profile.id] = _redactSensitive('$error');
      });
    } finally {
      socket?.destroy();
      if (mounted) {
        setState(() => _profilePingBusy[profile.id] = false);
      }
    }
  }

  String _profilePingLabel(VpnProfile profile) {
    if (_profilePingBusy[profile.id] == true) {
      return '...';
    }
    final text = _profilePingText[profile.id];
    if (text != null) {
      return text;
    }
    final ms = _profilePingMs[profile.id];
    if (ms != null) {
      return '$ms ms';
    }
    if (_profilePingError.containsKey(profile.id)) {
      return 'offline';
    }
    return 'ping';
  }

  bool _usesUdpEndpoint(VpnProfile profile) {
    if (profile.kind == VpnProfileKind.hysteria ||
        profile.kind == VpnProfileKind.hysteria2) {
      return true;
    }

    final outbound = profile.outbound;
    if (outbound == null) {
      return false;
    }
    final type = outbound['type']?.toString().toLowerCase();
    return type == 'hysteria' || type == 'hysteria2' || type == 'hy2';
  }

  Future<void> _resolveProfileCountries(List<VpnProfile> profiles) async {
    if (_countryResolveInFlight || profiles.isEmpty) {
      return;
    }

    _countryResolveInFlight = true;
    try {
      for (final profile in profiles.take(48)) {
        if (!mounted) {
          return;
        }
        if (_leadingFlag(profile.name) != null ||
            (profile.countryCode ?? '').trim().isNotEmpty) {
          continue;
        }

        final geo = await _geoService.resolveEndpointCountry(profile);
        if (geo != null) {
          await _saveProfileCountry(profile.id, geo);
        }
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    } finally {
      _countryResolveInFlight = false;
    }
  }

  Future<void> _refreshConnectedCountry(String profileId) async {
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (!mounted || _status != AurumVpnStatus.started) {
      return;
    }

    final geo = await _geoService.resolveExitCountryThroughTunnel();
    if (geo != null) {
      await _saveProfileCountry(profileId, geo);
      _queueLog(
        'Geo: exit country ${geo.countryCode}'
        '${geo.ip == null ? '' : ' via ${geo.ip}'}',
      );
    }
  }

  Future<void> _saveProfileCountry(String profileId, ProfileGeo geo) async {
    final index = _profiles.indexWhere((profile) => profile.id == profileId);
    if (index < 0) {
      return;
    }

    final current = _profiles[index];
    if (current.countryCode == geo.countryCode &&
        current.countryName == geo.countryName) {
      return;
    }

    final next = [..._profiles];
    next[index] = current.copyWith(
      countryCode: geo.countryCode,
      countryName: geo.countryName,
    );
    await _store.saveProfiles(next);
    if (!mounted) {
      return;
    }
    setState(() => _profiles = next);
  }

  String? _profileCountryFlag(VpnProfile profile) {
    final existing = _leadingFlag(profile.name);
    if (existing != null) {
      return existing;
    }

    final cached = ProfileGeo.countryCodeToFlag(profile.countryCode);
    if (cached != null) {
      return cached;
    }

    final haystack = '${profile.name} ${profile.server ?? ''}'.toLowerCase();
    if (haystack.contains('росси') ||
        haystack.contains('russia') ||
        haystack.endsWith('.ru') ||
        haystack.endsWith('.su') ||
        haystack.endsWith('.рф')) {
      return '🇷🇺';
    }
    if (haystack.contains('фин') ||
        haystack.contains('finland') ||
        haystack.endsWith('.fi')) {
      return '🇫🇮';
    }
    if (haystack.contains('герман') ||
        haystack.contains('germany') ||
        haystack.endsWith('.de')) {
      return '🇩🇪';
    }
    if (haystack.contains('сша') ||
        haystack.contains('usa') ||
        haystack.contains('america') ||
        haystack.endsWith('.us')) {
      return '🇺🇸';
    }
    if (haystack.contains('japan') || haystack.contains('япон')) {
      return '🇯🇵';
    }
    if (haystack.contains('netherlands') || haystack.contains('нидер')) {
      return '🇳🇱';
    }
    if (haystack.contains('france') || haystack.contains('франц')) {
      return '🇫🇷';
    }
    if (haystack.contains('canada') || haystack.contains('канада')) {
      return '🇨🇦';
    }
    if (haystack.contains('turkey') || haystack.contains('турц')) {
      return '🇹🇷';
    }
    if (haystack.contains('uk') ||
        haystack.contains('united kingdom') ||
        haystack.endsWith('.co.uk')) {
      return '🇬🇧';
    }
    return '🌐';
  }

  String _profileDisplayName(VpnProfile profile) {
    final trimmed = profile.name.trimLeft();
    if (_leadingFlag(trimmed) != null) {
      return String.fromCharCodes(trimmed.runes.skip(2)).trimLeft();
    }
    return profile.name;
  }

  String? _leadingFlag(String value) {
    final runes = value.trimLeft().runes.take(2).toList(growable: false);
    if (runes.length < 2) {
      return null;
    }
    final isFlag = runes.every((rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF);
    return isFlag ? String.fromCharCodes(runes) : null;
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) {
      return '00:00';
    }
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return [
        hours.toString().padLeft(2, '0'),
        minutes.toString().padLeft(2, '0'),
        seconds.toString().padLeft(2, '0'),
      ].join(':');
    }
    return [
      minutes.toString().padLeft(2, '0'),
      seconds.toString().padLeft(2, '0'),
    ].join(':');
  }

  Future<void> _setLanguage(_AppLanguage language) async {
    if (_language == language) {
      return;
    }
    await _store.saveLanguageCode(language.code);
    if (!mounted) {
      return;
    }
    final strings = _Strings.forLanguage(language);
    setState(() {
      _language = language;
      _message = strings.languageChanged;
    });
    try {
      await _vpnEngine
          .setNotificationDescription(strings.notificationDescription)
          .timeout(_nativeShortTimeout);
    } on Object {
      // Native plugin is unavailable in widget tests and desktop preview.
    }
  }

  String _profileKindLabel(VpnProfileKind kind) {
    return switch (kind) {
      VpnProfileKind.vlessReality => 'VLESS Reality',
      VpnProfileKind.vlessTls => 'VLESS TLS',
      VpnProfileKind.naive => 'NaiveProxy',
      VpnProfileKind.hysteria2 => 'Hysteria2',
      VpnProfileKind.hysteria => 'Hysteria',
      VpnProfileKind.singBoxConfig => 'Sing-box',
    };
  }

  Future<void> _deleteProfile(VpnProfile profile) async {
    if (_busy) {
      return;
    }

    await _runBusy(() async {
      final wasSelected = _selectedProfileId == profile.id;
      if (wasSelected && _connected) {
        _autoRecoveryArmed = false;
        await _stopVpnCore(updateMessage: true);
      }

      final next = _profiles
          .where((item) => item.id != profile.id)
          .toList(growable: false);
      final nextSelectedId = wasSelected
          ? (next.isEmpty ? null : next.first.id)
          : _selectedProfileId;

      await _store.saveProfiles(next);
      await _store.saveSelectedProfileId(nextSelectedId);
      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = next;
        _selectedProfileId = nextSelectedId;
        _profilePingMs.remove(profile.id);
        _profilePingBusy.remove(profile.id);
        _profilePingError.remove(profile.id);
        if (next.isEmpty ||
            !next.any((item) => _profileMatchesTab(item, _profileTab))) {
          _profileTab = _ProfileTab.all;
        }
        _message = s.profileDeleted;
      });
    }, message: s.working);
  }

  Future<void> _copySelected() async {
    final selected = _selectedProfile;
    if (selected == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: selected.originalInput));
    _showSnack(s.linkCopied);
  }

  Future<void> _showQr() async {
    final selected = _selectedProfile;
    if (selected == null || selected.originalInput.trim().isEmpty) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(selected.name),
          content: SizedBox(
            width: 260,
            child: QrImageView(
              data: selected.originalInput,
              version: QrVersions.auto,
              backgroundColor: Colors.white,
              size: 240,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.close),
            ),
          ],
        );
      },
    );
  }

  Future<T> _nativeCall<T>(
    String label,
    Future<T> future, {
    required Duration timeout,
  }) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      final message = 'Native call timeout [$label]';
      _queueLog(message);
      throw TimeoutException(message, timeout);
    }
  }

  int _eventInt(Object? value) {
    return switch (value) {
      int() => value,
      num() => value.round(),
      String() => int.tryParse(value) ?? 0,
      _ => 0,
    };
  }

  Future<void> _bestEffortNative<T>(
    String label,
    Future<T> future, {
    Duration timeout = _nativeShortTimeout,
  }) async {
    try {
      await _nativeCall(label, future, timeout: timeout);
    } on Object catch (error) {
      _queueLog('Native call ignored [$label]: ${_redactSensitive('$error')}');
    }
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    String? message,
  }) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = message ?? s.working;
    });
    try {
      await action();
    } on Object catch (error) {
      final errorText = _redactSensitive('$error');
      if (mounted) {
        setState(() {
          _lastError = errorText;
          _message = errorText;
        });
        _showSnack(
          errorText,
          action: SnackBarAction(
            label: s.report,
            onPressed: () => unawaited(_emailDeveloper()),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showSnack(String text, {SnackBarAction? action}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _openUrl(String value) async {
    final uri = Uri.parse(value);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showSnack(s.cannotOpenLink);
    }
  }

  Future<void> _checkAndInstallUpdate() async {
    if (_updateBusy) {
      return;
    }

    setState(() {
      _updateBusy = true;
      _updateProgress = null;
      _updateMessage = s.updateChecking;
    });

    try {
      final abis = await _updateService.supportedAbis();
      final update = await _updateService.findLatest(
        currentVersion: _appVersion,
        supportedAbis: abis,
      );
      if (update == null) {
        if (mounted) {
          setState(() => _updateMessage = s.updateNoUpdates(_appVersion));
        }
        return;
      }

      if (mounted) {
        setState(() => _updateMessage = s.updateDownloading(update.version));
      }

      final file = await _updateService.download(
        update,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _updateProgress = progress;
            _updateMessage = progress == null
                ? s.updateDownloading(update.version)
                : s.updateDownloadingProgress(
                    update.version,
                    (progress * 100).round().clamp(0, 100),
                  );
          });
        },
      );

      if (mounted) {
        setState(() => _updateMessage = s.updateInstalling(update.version));
      }
      await _updateService.installApk(file);
      if (mounted) {
        setState(() => _updateMessage = s.updateInstallerOpened);
      }
    } on AppUpdatePermissionException {
      if (mounted) {
        setState(() => _updateMessage = s.updateInstallPermission);
        _showSnack(
          s.updateInstallPermission,
          action: SnackBarAction(
            label: s.openSettings,
            onPressed: () => unawaited(_updateService.openInstallSettings()),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _updateMessage = s.updateFailed(_redactSensitive('$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _updateBusy = false);
      }
    }
  }

  Future<void> _emailDeveloper() async {
    await _loadBufferedLogs();
    final report = _buildDiagnosticReport();
    final uri = Uri.parse(
      'mailto:$_supportEmail?subject=${Uri.encodeComponent(s.mailSubject)}&body=${Uri.encodeComponent(report)}',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: report));
      _showSnack(s.mailFallback);
    }
  }

  String _buildDiagnosticReport() {
    final profile = _selectedProfile;
    final now = DateTime.now();
    final lines = <String>[
      '$_appName diagnostic',
      'app_version: $_appVersion',
      'generated_local: ${now.toIso8601String()}',
      'generated_utc: ${now.toUtc().toIso8601String()}',
      'platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'locale: ${Platform.localeName}',
      'config_target: ${_vpnEngine.configTarget.name}',
      if (_lastConfigSummary != null) 'config: $_lastConfigSummary',
      'status: $_status',
      'connection_degraded: $_connectionDegraded',
      'message: ${_redactSensitive(_message)}',
      if (_lastError != null) 'last_error: $_lastError',
      'uptime: ${_formatDuration(_connectedDuration)}',
      'auto_recovery_armed: $_autoRecoveryArmed',
      'auto_reconnect_attempts: $_autoReconnectAttempts',
      'health_failures: $_tunnelHealthFailures',
      if (_lastTrafficAt != null)
        'last_traffic_local: ${_lastTrafficAt!.toIso8601String()}',
      if (_lastHealthyAt != null)
        'last_healthy_local: ${_lastHealthyAt!.toIso8601String()}',
      if (profile != null) ...[
        'profile: ${_redactSensitive(profile.name)}',
        'protocol: ${_profileKindLabel(profile.kind)}',
        'endpoint: ${_redactSensitive(profile.endpoint)}',
        'country: ${_profileCountryFlag(profile) ?? 'unknown'}'
            '${profile.countryCode == null ? '' : ' ${profile.countryCode}'}'
            '${profile.countryName == null ? '' : ' ${profile.countryName}'}',
        'profile_ping: ${_profilePingLabel(profile)}',
      ],
      'traffic: up=$_uplink down=$_downlink total=$_sessionTotal',
      '',
      'profiles:',
      if (_profiles.isEmpty)
        'none'
      else
        ..._profiles.map((item) {
          final expires = item.subscriptionExpiresAt?.toUtc().toIso8601String();
          return [
            '- ${_redactSensitive(item.name)}',
            _profileKindLabel(item.kind),
            _redactSensitive(item.endpoint),
            'country=${_profileCountryFlag(item) ?? 'unknown'}'
                '${item.countryCode == null ? '' : ' ${item.countryCode}'}',
            'ping=${_profilePingLabel(item)}',
            if (expires != null) 'expires=$expires',
          ].join(' | ');
        }),
      '',
      'logs:',
    ];

    final safeLogs = [..._logs, ..._pendingLogs]
        .toList()
        .reversed
        .take(120)
        .toList()
        .reversed
        .where((log) => !_isDiagnosticNoise(log))
        .map(_redactSensitive);
    lines.addAll(safeLogs.isEmpty ? const ['Логов пока нет.'] : safeLogs);
    return lines.join('\n');
  }

  String _summarizeSingBoxConfig(
    String config, {
    required SingBoxConfigTarget target,
  }) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map) {
        return 'target=${target.name}; raw/custom config';
      }
      final map = decoded.cast<String, dynamic>();
      final inbounds = ((map['inbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final tun = inbounds.firstWhere(
        (inbound) => inbound['type'] == 'tun',
        orElse: () => const <String, dynamic>{},
      );
      final hasMixedProxy = inbounds.any(
        (inbound) =>
            inbound['type'] == 'mixed' &&
            inbound['listen'] == '127.0.0.1' &&
            inbound['listen_port'] == SingBoxConfigBuilder.localMixedProxyPort,
      );
      final outbounds = ((map['outbounds'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final proxy = outbounds.firstWhere(
        (outbound) => outbound['tag'] == 'proxy',
        orElse: () =>
            outbounds.isEmpty ? const <String, dynamic>{} : outbounds.first,
      );
      final dns = (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {};
      final dnsFinal = dns['final'] ?? 'unknown';
      final dnsServers = ((dns['servers'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final hasFakeDns = dnsServers.any((server) => server['type'] == 'fakeip');
      final dnsServer = dnsServers.firstWhere(
        (server) => server['tag'] == dnsFinal,
        orElse: () => const <String, dynamic>{},
      );
      return [
        'target=${target.name}',
        'proxy=${proxy['type'] ?? 'unknown'}',
        'dns=$dnsFinal/${dnsServer['type'] ?? 'unknown'}',
        if (hasFakeDns) 'fake_dns=true',
        'mtu=${tun['mtu'] ?? 'unknown'}',
        'strict_route=${tun['strict_route'] ?? 'unknown'}',
        'stack=${tun['stack'] ?? 'unknown'}',
        'network=${proxy['network_strategy'] ?? 'default'}',
        if (proxy['type'] == 'http') 'mode=https-connect',
        if (proxy['type'] == 'naive') 'mode=naive-native',
        if (proxy['type'] == 'http' || proxy['type'] == 'naive')
          'health_probe=mixed-proxy',
        if (proxy['type'] == 'naive')
          'transport=${proxy['quic'] == true ? 'h3/quic' : 'h2'}',
        if (proxy['type'] == 'vless')
          'packet=${proxy['packet_encoding'] ?? 'default'}',
        if (proxy['type'] == 'hysteria2' || proxy['type'] == 'hysteria')
          'transport=udp',
        'mixed_proxy=$hasMixedProxy',
      ].join('; ');
    } on Object {
      return 'target=${target.name}; raw/custom config';
    }
  }

  bool _isDiagnosticNoise(String log) {
    return log.contains('router: found package name:') ||
        log.contains('router: found user id:') ||
        log.contains('router: failed to search process: process not found');
  }

  Future<void> _setLogsExpanded(bool expanded) async {
    if (_logsExpanded == expanded) {
      return;
    }
    _logsExpanded = expanded;

    if (!expanded) {
      await _logSubscription?.cancel();
      _logSubscription = null;
      _pendingLogs.clear();
      _logFlushTimer?.cancel();
      _logFlushTimer = null;
      return;
    }

    _startLogStreaming();
    await _loadBufferedLogs();
  }

  void _startLogStreaming() {
    if (_logSubscription != null) {
      return;
    }

    _logSubscription = _vpnEngine.onLogMessage.listen((event) {
      if (!mounted || !_logsExpanded || event['type'] != 'log') {
        return;
      }
      final message = event['message'] as String?;
      if (message == null || message.isEmpty) {
        return;
      }
      _queueLog(message);
    });
  }

  Future<void> _loadBufferedLogs() async {
    try {
      final bufferedLogs = await _vpnEngine.getLogs().timeout(
        const Duration(seconds: 2),
        onTimeout: () => const <String>[],
      );
      final cleaned = bufferedLogs
          .map(_cleanLog)
          .where((log) => log.isNotEmpty)
          .toList()
          .reversed
          .take(60)
          .toList()
          .reversed
          .toList();
      if (mounted && cleaned.isNotEmpty) {
        setState(() {
          _logs
            ..clear()
            ..addAll(cleaned);
        });
      }
    } on Object {
      // Logs are optional and should never slow down VPN startup.
    }
  }

  String _redactSensitive(String value) {
    return value
        .replaceAllMapped(
          RegExp(r'(naive\+https://)[^:@\s]+:[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(r'(vless://)[^@\s]+@', caseSensitive: false),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:hy2|hysteria2|hysteria)://)[^@\s]+@',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***@',
        )
        .replaceAllMapped(
          RegExp(r'(https?://)[^:@/\s]+:[^@/\s]+@', caseSensitive: false),
          (match) => '${match[1]}***:***@',
        )
        .replaceAllMapped(
          RegExp(
            r'("(?:password|uuid|public_key|short_id|auth|auth_str)"\s*:\s*")[^"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}***',
        );
  }

  void _queueLog(String message) {
    final cleaned = _cleanLog(message);
    if (cleaned.isEmpty) {
      return;
    }

    _pendingLogs.add(cleaned);
    if (_pendingLogs.length > _maxPendingLogs) {
      _pendingLogs.removeRange(0, _pendingLogs.length - _maxPendingLogs);
    }

    _logFlushTimer ??= Timer(const Duration(milliseconds: 250), () {
      _logFlushTimer = null;
      if (!mounted || _pendingLogs.isEmpty) {
        return;
      }

      setState(() {
        _logs.addAll(_pendingLogs);
        _pendingLogs.clear();
        if (_logs.length > _maxStoredLogs) {
          _logs.removeRange(0, _logs.length - _maxStoredLogs);
        }
      });
    });
  }

  String _cleanLog(String message) {
    return message.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedProfile;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              child: Image(
                image: AssetImage('assets/images/app_icon.png'),
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
            SizedBox(width: 10),
            Text(_appName),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _StatusPanel(
              strings: s,
              status: _status,
              degraded: _connectionDegraded,
              message: _message,
              uplink: _uplink,
              downlink: _downlink,
              uptime: _formatDuration(_connectedDuration),
              onToggle: _toggleVpn,
              toggleEnabled: !_busy && selected != null,
            ),
            const SizedBox(height: 16),
            _ProfilePanel(
              strings: s,
              profiles: _profiles,
              selectedProfile: selected,
              selectedId: selected?.id,
              selectedTab: _profileTab,
              onTabChanged: (tab) => setState(() => _profileTab = tab),
              onSelect: _selectProfile,
              onAdd: _showImportSheet,
              onCopy: selected == null ? null : _copySelected,
              onQr: selected == null ? null : _showQr,
              onDeleteProfile: (profile) => unawaited(_deleteProfile(profile)),
              onRefreshSubscriptions: () => unawaited(_refreshSubscriptions()),
              hasSubscriptionSources: _profiles.isNotEmpty,
              subscriptionRefreshBusy: _subscriptionRefreshBusy,
              subscriptionStatus: _subscriptionTileStatus,
              subscriptionNeedsAttention: _subscriptionNeedsAttention,
              kindLabel: _profileKindLabel,
              displayName: _profileDisplayName,
              countryFlag: _profileCountryFlag,
              pingLabel: _profilePingLabel,
              onPingAll: () => unawaited(_pingProfiles(_profiles)),
              onPing: (profile) => unawaited(_pingProfile(profile)),
            ),
            const SizedBox(height: 16),
            _SupportPanel(
              strings: s,
              selectedTab: _supportTab,
              onTabChanged: (tab) => setState(() => _supportTab = tab),
              language: _language,
              onLanguageChanged: (language) =>
                  unawaited(_setLanguage(language)),
              onSupport: () => _openUrl(_telegramUrl),
              onTelegram: () => _openUrl(_telegramUrl),
              onVk: () => _openUrl(_vkUrl),
              onDonate: () => _openUrl(_donateUrl),
              onDeveloper: _emailDeveloper,
            ),
            const SizedBox(height: 16),
            _UpdatePanel(
              strings: s,
              currentVersion: _appVersion,
              message: _updateMessage,
              busy: _updateBusy,
              progress: _updateProgress,
              onCheck: _checkAndInstallUpdate,
            ),
            const SizedBox(height: 16),
            _FaqPanel(strings: s),
            const SizedBox(height: 16),
            _LogsPanel(
              strings: s,
              logs: _logs,
              onExpansionChanged: (expanded) =>
                  unawaited(_setLogsExpanded(expanded)),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.strings,
    required this.status,
    required this.degraded,
    required this.message,
    required this.uplink,
    required this.downlink,
    required this.uptime,
    required this.onToggle,
    required this.toggleEnabled,
  });

  final _Strings strings;
  final String status;
  final bool degraded;
  final String message;
  final String uplink;
  final String downlink;
  final String uptime;
  final VoidCallback onToggle;
  final bool toggleEnabled;

  @override
  Widget build(BuildContext context) {
    final connected = status == AurumVpnStatus.started;
    final statusLabel = switch (status) {
      AurumVpnStatus.started =>
        degraded ? strings.connectionProblem : strings.connected,
      AurumVpnStatus.starting => strings.connecting,
      AurumVpnStatus.stopping => strings.disconnecting,
      _ => strings.stopped,
    };
    final accent = degraded
        ? _danger
        : connected
        ? _gold
        : Colors.white12;
    final glow = degraded
        ? _danger.withValues(alpha: 0.22)
        : connected
        ? _gold.withValues(alpha: 0.18)
        : Colors.black26;

    return SizedBox(
      height: 212,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent),
          boxShadow: [
            BoxShadow(color: glow, blurRadius: 18, offset: const Offset(0, 8)),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    degraded
                        ? Icons.warning_amber_rounded
                        : connected
                        ? Icons.verified_user
                        : Icons.shield_outlined,
                    color: degraded
                        ? _dangerSoft
                        : connected
                        ? _goldSoft
                        : _mutedGold,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _mutedGold),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _Metric(label: '↑', value: uplink, fixed: true),
                  ),
                  const SizedBox(width: 14),
                  _UptimeButton(
                    connected: connected,
                    degraded: degraded,
                    uptime: uptime,
                    enabled: toggleEnabled,
                    onPressed: onToggle,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _Metric(label: '↓', value: downlink, fixed: true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UptimeButton extends StatelessWidget {
  const _UptimeButton({
    required this.connected,
    required this.degraded,
    required this.uptime,
    required this.enabled,
    required this.onPressed,
  });

  final bool connected;
  final bool degraded;
  final String uptime;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: connected ? 'Время работы VPN' : 'Подключить',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: connected
                  ? degraded
                        ? const [
                            Color(0xFFFFD7DF),
                            Color(0xFFFF6B81),
                            Color(0xFFFF244A),
                          ]
                        : const [
                            Color(0xFFEAF7FF),
                            Color(0xFF22D3EE),
                            Color(0xFF0EA5FF),
                          ]
                  : const [Color(0xFF10283B), _surfaceMetric],
            ),
            border: Border.all(
              color: degraded
                  ? const Color(0xFFFFB3C0)
                  : connected
                  ? const Color(0xFFA7F3FF)
                  : _gold.withValues(alpha: 0.35),
              width: connected ? 2.2 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: degraded
                    ? _danger.withValues(alpha: 0.56)
                    : connected
                    ? const Color(0xFF00C8FF).withValues(alpha: 0.58)
                    : Colors.black38,
                blurRadius: connected ? 34 : 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onPressed : null,
            child: SizedBox.square(
              dimension: 94,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      degraded
                          ? Icons.priority_high_rounded
                          : connected
                          ? Icons.timer_outlined
                          : Icons.power_settings_new,
                      color: connected ? _ink : _goldSoft,
                      size: 24,
                    ),
                    const SizedBox(height: 5),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        connected ? uptime : '00:00',
                        maxLines: 1,
                        style: TextStyle(
                          color: connected ? _ink : _goldSoft,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.fixed = false});

  final String label;
  final String value;
  final bool fixed;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      '$label $value',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(letterSpacing: 0),
    );

    return Container(
      height: fixed ? 52 : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _surfaceMetric,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      alignment: Alignment.center,
      child: fixed
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: text,
            )
          : text,
    );
  }
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel({
    required this.strings,
    required this.profiles,
    required this.selectedProfile,
    required this.selectedId,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onSelect,
    required this.onAdd,
    required this.onCopy,
    required this.onQr,
    required this.onDeleteProfile,
    required this.onRefreshSubscriptions,
    required this.hasSubscriptionSources,
    required this.subscriptionRefreshBusy,
    required this.subscriptionStatus,
    required this.subscriptionNeedsAttention,
    required this.kindLabel,
    required this.displayName,
    required this.countryFlag,
    required this.pingLabel,
    required this.onPingAll,
    required this.onPing,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final VpnProfile? selectedProfile;
  final String? selectedId;
  final _ProfileTab selectedTab;
  final ValueChanged<_ProfileTab> onTabChanged;
  final ValueChanged<VpnProfile> onSelect;
  final VoidCallback onAdd;
  final VoidCallback? onCopy;
  final VoidCallback? onQr;
  final ValueChanged<VpnProfile> onDeleteProfile;
  final VoidCallback onRefreshSubscriptions;
  final bool hasSubscriptionSources;
  final bool subscriptionRefreshBusy;
  final String? Function(VpnProfile profile) subscriptionStatus;
  final bool Function(VpnProfile profile) subscriptionNeedsAttention;
  final String Function(VpnProfileKind kind) kindLabel;
  final String Function(VpnProfile profile) displayName;
  final String? Function(VpnProfile profile) countryFlag;
  final String Function(VpnProfile profile) pingLabel;
  final VoidCallback onPingAll;
  final ValueChanged<VpnProfile> onPing;

  @override
  Widget build(BuildContext context) {
    final visibleProfiles = profiles
        .where((profile) => _profileMatchesTab(profile, selectedTab))
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.profiles,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: strings.refreshSubscriptions,
              onPressed: hasSubscriptionSources && !subscriptionRefreshBusy
                  ? onRefreshSubscriptions
                  : null,
              icon: subscriptionRefreshBusy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
            IconButton(
              tooltip: strings.refreshPing,
              onPressed: profiles.isEmpty ? null : onPingAll,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: strings.addProfile,
              onPressed: onAdd,
              icon: const Icon(Icons.add_link),
            ),
            IconButton(
              tooltip: strings.showQr,
              onPressed: onQr,
              icon: const Icon(Icons.qr_code_2),
            ),
            IconButton(
              tooltip: strings.copy,
              onPressed: onCopy,
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ProfileTabBar(
          strings: strings,
          profiles: profiles,
          selectedTab: selectedTab,
          onChanged: onTabChanged,
        ),
        const SizedBox(height: 10),
        if (profiles.isEmpty)
          _EmptyProfiles(strings: strings)
        else if (visibleProfiles.isEmpty)
          _EmptyProfiles(message: strings.noProfilesInTab(selectedTab))
        else
          ...visibleProfiles.map(
            (profile) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProfileTile(
                profile: profile,
                selected: profile.id == selectedId,
                onTap: () => onSelect(profile),
                kindLabel: kindLabel,
                displayName: displayName(profile),
                countryFlag: countryFlag(profile),
                pingLabel: pingLabel(profile),
                subscriptionStatus: subscriptionStatus(profile),
                subscriptionNeedsAttention: subscriptionNeedsAttention(profile),
                subscriptionLabel: strings.subscriptionLabel,
                onPing: () => onPing(profile),
                onDelete: () => onDeleteProfile(profile),
                deleteTooltip: strings.delete,
              ),
            ),
          ),
        const SizedBox(height: 6),
        _ProfileInsightPanel(
          strings: strings,
          profile: selectedProfile,
          kindLabel: kindLabel,
          countryFlag: selectedProfile == null
              ? null
              : countryFlag(selectedProfile!),
          pingLabel: selectedProfile == null
              ? null
              : pingLabel(selectedProfile!),
          subscriptionStatus: selectedProfile == null
              ? null
              : strings.subscriptionStatus(
                  selectedProfile!.subscriptionExpiresAt,
                ),
          subscriptionNeedsAttention: selectedProfile == null
              ? false
              : subscriptionNeedsAttention(selectedProfile!),
          canRefreshSubscriptions: hasSubscriptionSources,
          subscriptionRefreshBusy: subscriptionRefreshBusy,
          onRefreshSubscriptions: onRefreshSubscriptions,
          onPing: selectedProfile == null
              ? null
              : () => onPing(selectedProfile!),
        ),
      ],
    );
  }
}

class _ProfileTabBar extends StatelessWidget {
  const _ProfileTabBar({
    required this.strings,
    required this.profiles,
    required this.selectedTab,
    required this.onChanged,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final _ProfileTab selectedTab;
  final ValueChanged<_ProfileTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in _ProfileTab.values) ...[
            ChoiceChip(
              label: Text(strings.profileTabLabel(tab, _countFor(tab))),
              selected: selectedTab == tab,
              showCheckmark: false,
              onSelected: (_) => onChanged(tab),
              selectedColor: _gold.withValues(alpha: 0.9),
              backgroundColor: _surface,
              labelStyle: TextStyle(
                color: selectedTab == tab ? _ink : _goldSoft,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: selectedTab == tab
                      ? _goldSoft
                      : _gold.withValues(alpha: 0.2),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  int _countFor(_ProfileTab tab) {
    if (tab == _ProfileTab.all) {
      return profiles.length;
    }
    return profiles.where((profile) => _profileMatchesTab(profile, tab)).length;
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.selected,
    required this.onTap,
    required this.kindLabel,
    required this.displayName,
    required this.countryFlag,
    required this.pingLabel,
    required this.subscriptionStatus,
    required this.subscriptionNeedsAttention,
    required this.subscriptionLabel,
    required this.onPing,
    required this.onDelete,
    required this.deleteTooltip,
  });

  final VpnProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final String Function(VpnProfileKind kind) kindLabel;
  final String displayName;
  final String? countryFlag;
  final String pingLabel;
  final String? subscriptionStatus;
  final bool subscriptionNeedsAttention;
  final String subscriptionLabel;
  final VoidCallback onPing;
  final VoidCallback onDelete;
  final String deleteTooltip;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? _gold.withValues(alpha: 0.18) : _surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _gold : Colors.white12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Center(
                child: countryFlag == null
                    ? Icon(switch (profile.kind) {
                        VpnProfileKind.naive => Icons.public,
                        VpnProfileKind.hysteria2 ||
                        VpnProfileKind.hysteria => Icons.speed_outlined,
                        _ => Icons.bolt,
                      }, color: selected ? _goldSoft : _mutedGold)
                    : Text(countryFlag!, style: const TextStyle(fontSize: 22)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${kindLabel(profile.kind)} · ${profile.endpoint}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _mutedGold),
                  ),
                  if (subscriptionStatus != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '$subscriptionLabel · $subscriptionStatus',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subscriptionNeedsAttention
                            ? _dangerSoft
                            : _mutedGold,
                        fontSize: 12,
                        fontWeight: subscriptionNeedsAttention
                            ? FontWeight.w700
                            : FontWeight.w400,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkResponse(
              onTap: onPing,
              radius: 28,
              child: Container(
                constraints: const BoxConstraints(minWidth: 64),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: _surfaceMetric,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _gold.withValues(alpha: 0.18)),
                ),
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    pingLabel,
                    maxLines: 1,
                    style: const TextStyle(
                      color: _goldSoft,
                      fontSize: 12,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: deleteTooltip,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              color: selected ? _goldSoft : _mutedGold,
              iconSize: 20,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({this.strings, this.message});

  final _Strings? strings;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(message ?? strings!.emptyProfiles),
    );
  }
}

class _ProfileInsightPanel extends StatelessWidget {
  const _ProfileInsightPanel({
    required this.strings,
    required this.profile,
    required this.kindLabel,
    required this.countryFlag,
    required this.pingLabel,
    required this.subscriptionStatus,
    required this.subscriptionNeedsAttention,
    required this.canRefreshSubscriptions,
    required this.subscriptionRefreshBusy,
    required this.onRefreshSubscriptions,
    required this.onPing,
  });

  final _Strings strings;
  final VpnProfile? profile;
  final String Function(VpnProfileKind kind) kindLabel;
  final String? countryFlag;
  final String? pingLabel;
  final String? subscriptionStatus;
  final bool subscriptionNeedsAttention;
  final bool canRefreshSubscriptions;
  final bool subscriptionRefreshBusy;
  final VoidCallback onRefreshSubscriptions;
  final VoidCallback? onPing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surfaceMetric.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.health_and_safety_outlined, color: _goldSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.profileInsight,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (profile == null)
              Text(
                strings.profileInsightEmpty,
                style: const TextStyle(color: _mutedGold),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      _InsightRow(
                        icon: Icons.route_outlined,
                        label: strings.protocolLabel,
                        value: kindLabel(profile!.kind),
                      ),
                      _InsightRow(
                        icon: Icons.network_cell_outlined,
                        label: strings.networkLabel,
                        value: strings.mobileReady,
                      ),
                      _InsightRow(
                        icon: Icons.dns_outlined,
                        label: strings.dnsLabel,
                        value: strings.dnsCountryValue,
                      ),
                      _InsightRow(
                        icon: Icons.security_update_good_outlined,
                        label: strings.stabilityLabel,
                        value: strings.stabilityValue,
                      ),
                      _InsightRow(
                        icon: Icons.event_available_outlined,
                        label: strings.subscriptionLabel,
                        value:
                            subscriptionStatus ?? strings.subscriptionUnknown,
                        valueColor: subscriptionNeedsAttention
                            ? _dangerSoft
                            : null,
                        trailing: subscriptionRefreshBusy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap:
                            canRefreshSubscriptions && !subscriptionRefreshBusy
                            ? onRefreshSubscriptions
                            : null,
                      ),
                      if (countryFlag != null)
                        _InsightRow(
                          icon: Icons.flag_outlined,
                          label: strings.countryLabel,
                          value: countryFlag!,
                        ),
                      _InsightRow(
                        icon: Icons.speed_outlined,
                        label: strings.pingLabel,
                        value: pingLabel ?? 'ping',
                        onTap: onPing,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    strings.mobileNetworkAdvice,
                    style: const TextStyle(color: _mutedGold, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.androidVpnVisibleNote,
                    style: const TextStyle(
                      color: _mutedGold,
                      height: 1.35,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${strings.endpointLabel}: ${profile!.endpoint}',
                    style: const TextStyle(color: _mutedGold),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, color: _goldSoft, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _mutedGold, letterSpacing: 0),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: _goldSoft,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ).copyWith(color: valueColor),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ] else if (onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.refresh, color: _mutedGold, size: 16),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return child;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: child,
    );
  }
}

class _SupportPanel extends StatelessWidget {
  const _SupportPanel({
    required this.strings,
    required this.selectedTab,
    required this.onTabChanged,
    required this.language,
    required this.onLanguageChanged,
    required this.onSupport,
    required this.onTelegram,
    required this.onVk,
    required this.onDonate,
    required this.onDeveloper,
  });

  final _Strings strings;
  final _SupportTab selectedTab;
  final ValueChanged<_SupportTab> onTabChanged;
  final _AppLanguage language;
  final ValueChanged<_AppLanguage> onLanguageChanged;
  final VoidCallback onSupport;
  final VoidCallback onTelegram;
  final VoidCallback onVk;
  final VoidCallback onDonate;
  final VoidCallback onDeveloper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.contact,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            SegmentedButton<_SupportTab>(
              segments: [
                ButtonSegment(
                  value: _SupportTab.help,
                  label: Text(strings.supportTabLabel(_SupportTab.help)),
                ),
                ButtonSegment(
                  value: _SupportTab.community,
                  label: Text(strings.supportTabLabel(_SupportTab.community)),
                ),
              ],
              selected: {selectedTab},
              showSelectedIcon: false,
              onSelectionChanged: (value) {
                final selected = value.isEmpty ? null : value.first;
                if (selected != null) {
                  onTabChanged(selected);
                }
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                minimumSize: WidgetStateProperty.all(const Size(72, 36)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: selectedTab == _SupportTab.help
              ? [
                  OutlinedButton.icon(
                    onPressed: onSupport,
                    icon: const Icon(Icons.support_agent),
                    label: Text(strings.support),
                  ),
                  OutlinedButton.icon(
                    onPressed: onDeveloper,
                    icon: const Icon(Icons.mail_outline),
                    label: Text(strings.developer),
                  ),
                ]
              : [
                  OutlinedButton.icon(
                    onPressed: onTelegram,
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('Telegram'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onVk,
                    icon: const Icon(Icons.groups_outlined),
                    label: const Text('VK'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onDonate,
                    icon: const Icon(Icons.volunteer_activism_outlined),
                    label: Text(strings.donate),
                  ),
                ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(strings.language, style: const TextStyle(color: _mutedGold)),
            const SizedBox(width: 12),
            SegmentedButton<_AppLanguage>(
              segments: const [
                ButtonSegment(value: _AppLanguage.ru, label: Text('RU')),
                ButtonSegment(value: _AppLanguage.en, label: Text('EN')),
              ],
              selected: {language},
              showSelectedIcon: false,
              onSelectionChanged: (value) {
                final selected = value.isEmpty ? null : value.first;
                if (selected != null) {
                  onLanguageChanged(selected);
                }
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                minimumSize: WidgetStateProperty.all(const Size(54, 36)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel({
    required this.strings,
    required this.currentVersion,
    required this.message,
    required this.busy,
    required this.progress,
    required this.onCheck,
  });

  final _Strings strings;
  final String currentVersion;
  final String? message;
  final bool busy;
  final double? progress;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.system_update_alt, color: _goldSoft),
      title: Text(strings.updates),
      subtitle: Text(
        message ?? strings.updateIdle(currentVersion),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _mutedGold),
      ),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _gold.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.updateDescription,
                  style: const TextStyle(color: _mutedGold, height: 1.35),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.verified_outlined,
                      color: _goldSoft,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.updateChannel,
                        style: const TextStyle(color: _goldSoft, height: 1.25),
                      ),
                    ),
                  ],
                ),
                if (busy) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : onCheck,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_for_offline_outlined),
                  label: Text(strings.checkUpdates),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqPanel extends StatelessWidget {
  const _FaqPanel({required this.strings});

  final _Strings strings;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.help_outline, color: _goldSoft),
      title: Text(strings.faq),
      children: [
        for (final item in strings.faqItems)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.question,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.answer,
                      style: const TextStyle(color: _mutedGold, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({
    required this.strings,
    required this.logs,
    required this.onExpansionChanged,
  });

  final _Strings strings;
  final List<String> logs;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      onExpansionChanged: onExpansionChanged,
      tilePadding: EdgeInsets.zero,
      title: Text(strings.logs),
      children: [
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 92),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _gold.withValues(alpha: 0.18)),
          ),
          child: Text(
            logs.isEmpty ? strings.noLogs : logs.join('\n'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqItem {
  const _FaqItem({required this.question, required this.answer});

  final String question;
  final String answer;
}

class _Strings {
  const _Strings._({
    required this.addProfileHint,
    required this.nothingToImport,
    required this.switchingProfile,
    required this.importFirst,
    required this.configSaveFailed,
    required this.vpnStartFailed,
    required this.connectionProbeFailed,
    required this.disconnectingVpn,
    required this.vpnStopServiceFailed,
    required this.vpnStopped,
    required this.profileDeleted,
    required this.linkCopied,
    required this.close,
    required this.working,
    required this.report,
    required this.cannotOpenLink,
    required this.mailSubject,
    required this.mailFallback,
    required this.vpnStoppedUnexpectedly,
    required this.openLogsMessage,
    required this.languageChanged,
    required this.addProfile,
    required this.importHint,
    required this.importAction,
    required this.clipboard,
    required this.scanQr,
    required this.pasteFromClipboard,
    required this.language,
    required this.connected,
    required this.connectionProblem,
    required this.connecting,
    required this.disconnecting,
    required this.stopped,
    required this.profiles,
    required this.refreshPing,
    required this.showQr,
    required this.copy,
    required this.delete,
    required this.emptyProfiles,
    required this.profileInsight,
    required this.profileInsightEmpty,
    required this.protocolLabel,
    required this.networkLabel,
    required this.dnsLabel,
    required this.dnsCountryValue,
    required this.stabilityLabel,
    required this.stabilityValue,
    required this.countryLabel,
    required this.pingLabel,
    required this.subscriptionLabel,
    required this.subscriptionUnknown,
    required this.subscriptionExpired,
    required this.refreshSubscriptions,
    required this.refreshingSubscriptions,
    required this.noSubscriptionsToRefresh,
    required this.subscriptionReminderTitle,
    required this.mobileReady,
    required this.mobileNetworkAdvice,
    required this.androidVpnVisibleNote,
    required this.endpointLabel,
    required this.connect,
    required this.disconnect,
    required this.contact,
    required this.support,
    required this.donate,
    required this.developer,
    required this.updates,
    required this.updateDescription,
    required this.updateChannel,
    required this.checkUpdates,
    required this.updateChecking,
    required this.updateInstallerOpened,
    required this.updateInstallPermission,
    required this.openSettings,
    required this.faq,
    required this.faqItems,
    required this.logs,
    required this.noLogs,
    required this.notificationDescription,
  });

  final String addProfileHint;
  final String nothingToImport;
  final String switchingProfile;
  final String importFirst;
  final String configSaveFailed;
  final String vpnStartFailed;
  final String connectionProbeFailed;
  final String disconnectingVpn;
  final String vpnStopServiceFailed;
  final String vpnStopped;
  final String profileDeleted;
  final String linkCopied;
  final String close;
  final String working;
  final String report;
  final String cannotOpenLink;
  final String mailSubject;
  final String mailFallback;
  final String vpnStoppedUnexpectedly;
  final String openLogsMessage;
  final String languageChanged;
  final String addProfile;
  final String importHint;
  final String importAction;
  final String clipboard;
  final String scanQr;
  final String pasteFromClipboard;
  final String language;
  final String connected;
  final String connectionProblem;
  final String connecting;
  final String disconnecting;
  final String stopped;
  final String profiles;
  final String refreshPing;
  final String showQr;
  final String copy;
  final String delete;
  final String emptyProfiles;
  final String profileInsight;
  final String profileInsightEmpty;
  final String protocolLabel;
  final String networkLabel;
  final String dnsLabel;
  final String dnsCountryValue;
  final String stabilityLabel;
  final String stabilityValue;
  final String countryLabel;
  final String pingLabel;
  final String subscriptionLabel;
  final String subscriptionUnknown;
  final String subscriptionExpired;
  final String refreshSubscriptions;
  final String refreshingSubscriptions;
  final String noSubscriptionsToRefresh;
  final String subscriptionReminderTitle;
  final String mobileReady;
  final String mobileNetworkAdvice;
  final String androidVpnVisibleNote;
  final String endpointLabel;
  final String connect;
  final String disconnect;
  final String contact;
  final String support;
  final String donate;
  final String developer;
  final String updates;
  final String updateDescription;
  final String updateChannel;
  final String checkUpdates;
  final String updateChecking;
  final String updateInstallerOpened;
  final String updateInstallPermission;
  final String openSettings;
  final String faq;
  final List<_FaqItem> faqItems;
  final String logs;
  final String noLogs;
  final String notificationDescription;

  static _Strings forLanguage(_AppLanguage language) {
    return switch (language) {
      _AppLanguage.en => en,
      _ => ru,
    };
  }

  String loadedProfiles(int count) => switch (this) {
    _Strings.en => 'Profiles loaded: $count',
    _ => 'Загружено профилей: $count',
  };

  String imported(int count) => switch (this) {
    _Strings.en => 'Imported: $count',
    _ => 'Импортировано: $count',
  };

  String importedProfiles(int count) => switch (this) {
    _Strings.en => 'Profiles imported: $count',
    _ => 'Импортировано профилей: $count',
  };

  String subscriptionsUpdated(int count) => switch (this) {
    _Strings.en => 'Subscriptions updated: $count profiles',
    _ => 'Подписки обновлены: $count профилей',
  };

  String subscriptionRefreshFailed(String error) => switch (this) {
    _Strings.en => 'Subscription update failed: $error',
    _ => 'Обновление подписок не удалось: $error',
  };

  String subscriptionReminderBody(String profileName, String status) =>
      switch (this) {
        _Strings.en => '$profileName: $status. Time to renew the subscription.',
        _ => '$profileName: $status. Пора продлить подписку.',
      };

  String subscriptionReminderMany(
    int count,
    String profileName,
    String status,
  ) => switch (this) {
    _Strings.en =>
      '$count subscriptions need attention. First: $profileName, $status.',
    _ => '$count подписки требуют внимания. Первая: $profileName, $status.',
  };

  String profileTabLabel(_ProfileTab tab, int count) {
    final label = switch (tab) {
      _ProfileTab.all => switch (this) {
        _Strings.en => 'All',
        _ => 'Все',
      },
      _ProfileTab.vless => 'VLESS',
      _ProfileTab.naive => 'Naive',
      _ProfileTab.hysteria => 'Hysteria',
      _ProfileTab.singBox => 'JSON',
    };
    return '$label $count';
  }

  String noProfilesInTab(_ProfileTab tab) => switch (this) {
    _Strings.en => 'No profiles in this tab yet.',
    _ => 'В этой вкладке пока нет профилей.',
  };

  String supportTabLabel(_SupportTab tab) => switch (tab) {
    _SupportTab.help => switch (this) {
      _Strings.en => 'Help',
      _ => 'Помощь',
    },
    _SupportTab.community => switch (this) {
      _Strings.en => 'Project',
      _ => 'Проект',
    },
  };

  String selectedProfile(String name) => switch (this) {
    _Strings.en => 'Selected profile: $name',
    _ => 'Выбран профиль: $name',
  };

  String connectingTo(String name) => switch (this) {
    _Strings.en => 'Connecting to $name...',
    _ => 'Подключаю $name...',
  };

  String connectingStatus(String name) => switch (this) {
    _Strings.en => 'Connecting: $name',
    _ => 'Подключаюсь: $name',
  };

  String connectionProfile(String name) => switch (this) {
    _Strings.en => 'Connection: $name',
    _ => 'Подключение: $name',
  };

  String networkRecoveryPaused(String name) => switch (this) {
    _Strings.en =>
      'Mobile network is unstable. Auto reconnect is paused for $name.',
    _ => 'Мобильная сеть нестабильна. Автовосстановление для $name на паузе.',
  };

  String vpnNotConnected(String status) => switch (this) {
    _Strings.en => 'VPN did not reach Connected. Last status: $status.',
    _ => 'VPN не вышел в статус "Подключено". Последний статус: $status.',
  };

  String vpnStopTimeout(String status) => switch (this) {
    _Strings.en => 'VPN did not fully stop in time. Last status: $status.',
    _ => 'VPN не успел полностью остановиться. Последний статус: $status.',
  };

  String updateIdle(String version) => switch (this) {
    _Strings.en => 'Installed version: $version',
    _ => 'Установлена версия: $version',
  };

  String updateNoUpdates(String version) => switch (this) {
    _Strings.en => 'Version $version is current.',
    _ => 'Версия $version актуальна.',
  };

  String updateDownloading(String version) => switch (this) {
    _Strings.en => 'Downloading version $version...',
    _ => 'Скачиваю версию $version...',
  };

  String updateDownloadingProgress(String version, int percent) =>
      switch (this) {
        _Strings.en => 'Downloading version $version: $percent%',
        _ => 'Скачиваю версию $version: $percent%',
      };

  String updateInstalling(String version) => switch (this) {
    _Strings.en => 'Version $version downloaded. Opening installer...',
    _ => 'Версия $version скачана. Открываю установщик...',
  };

  String updateFailed(String error) => switch (this) {
    _Strings.en => 'Update failed: $error',
    _ => 'Обновление не удалось: $error',
  };

  String subscriptionStatus(DateTime? expiresAt) {
    if (expiresAt == null) {
      return subscriptionUnknown;
    }

    final remaining = expiresAt.toUtc().difference(DateTime.now().toUtc());
    if (remaining.isNegative) {
      return subscriptionExpired;
    }

    if (remaining.inHours < 24) {
      final hours = remaining.inHours.clamp(1, 23);
      return switch (this) {
        _Strings.en => '$hours h left',
        _ => 'Осталось $hours ч',
      };
    }

    final days = remaining.inDays + (remaining.inHours % 24 == 0 ? 0 : 1);
    return switch (this) {
      _Strings.en => '$days d left',
      _ => 'Осталось $days дн.',
    };
  }

  static const ru = _Strings._(
    addProfileHint: 'Добавь подписку Remnawave, QR или отдельный ключ',
    nothingToImport: 'Нечего импортировать.',
    switchingProfile: 'Переключаю профиль...',
    importFirst: 'Сначала импортируй профиль.',
    configSaveFailed: 'sing-box не сохранил config.',
    vpnStartFailed: 'VPN не стартовал. Открой логи ниже.',
    connectionProbeFailed:
        'VPN запустился, но проверка интернета через туннель не прошла.',
    disconnectingVpn: 'Отключаю VPN...',
    vpnStopServiceFailed: 'VPN-сервис не смог полностью остановиться.',
    vpnStopped: 'VPN остановлен',
    profileDeleted: 'Профиль удалён',
    linkCopied: 'Ссылка скопирована',
    close: 'Закрыть',
    working: 'Работаю...',
    report: 'Отчёт',
    cannotOpenLink: 'Не смог открыть ссылку.',
    mailSubject: 'Yurich Connect: диагностика VPN',
    mailFallback: 'Почта не открылась. Отчёт скопирован в буфер.',
    vpnStoppedUnexpectedly: 'VPN остановлен неожиданно',
    openLogsMessage: 'VPN остановлен. Открой логи sing-box.',
    languageChanged: 'Язык переключён',
    addProfile: 'Добавить профиль',
    importHint:
        'https://sub... или vless://... или naive+https://... или hy2://...',
    importAction: 'Импорт',
    clipboard: 'Буфер',
    scanQr: 'Сканировать QR',
    pasteFromClipboard: 'Вставить из буфера',
    language: 'Язык',
    connected: 'Подключено',
    connectionProblem: 'Нет стабильного соединения',
    connecting: 'Подключаюсь',
    disconnecting: 'Отключаюсь',
    stopped: 'Остановлено',
    profiles: 'Профили',
    refreshPing: 'Обновить пинг',
    showQr: 'Показать QR',
    copy: 'Скопировать',
    delete: 'Удалить',
    emptyProfiles:
        'Пока нет профилей. Нажми +, вставь подписку или сканируй QR.',
    profileInsight: 'Профиль и сеть',
    profileInsightEmpty:
        'Выбери профиль, чтобы увидеть параметры подключения и рекомендации.',
    protocolLabel: 'Протокол',
    networkLabel: 'Сеть',
    dnsLabel: 'DNS',
    dnsCountryValue: 'Через профиль',
    stabilityLabel: 'Стабильность',
    stabilityValue: 'Фоновый keeper',
    countryLabel: 'Страна',
    pingLabel: 'Пинг',
    subscriptionLabel: 'Подписка',
    subscriptionUnknown: 'Срок не указан',
    subscriptionExpired: 'Истекла',
    refreshSubscriptions: 'Обновить подписки',
    refreshingSubscriptions: 'Обновляю подписки...',
    noSubscriptionsToRefresh:
        'Не нашёл исходную ссылку подписки. Вставь https://.../links.txt один раз.',
    subscriptionReminderTitle: 'Пора продлить подписку',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Wi‑Fi/LTE: строгий TUN, FakeIP и DNS через выбранный профиль; keeper перепроверяет туннель без открытия приложения.',
    androidVpnVisibleNote:
        'Android может показать приложениям факт VPN. Yurich Connect защищает IP/DNS, но системный VpnService не скрывается без root/прошивки.',
    endpointLabel: 'Сервер',
    connect: 'Подключить',
    disconnect: 'Отключить',
    contact: 'Связь',
    support: 'Поддержка',
    donate: 'Донат',
    developer: 'Разработчику',
    updates: 'Обновления',
    updateDescription:
        'Приложение само проверит свежий APK, выберет файл под телефон и откроет установщик Android. Переходить на страницу релиза не нужно.',
    updateChannel: 'Канал обновлений: GitHub Releases',
    checkUpdates: 'Проверить и установить',
    updateChecking: 'Проверяю обновления...',
    updateInstallerOpened: 'Установщик Android открыт',
    updateInstallPermission:
        'Разреши установку приложений из Yurich Connect и нажми кнопку ещё раз.',
    openSettings: 'Настройки',
    faq: 'FAQ',
    faqItems: [
      _FaqItem(
        question: 'Как добавить подписку или ключ?',
        answer:
            'Нажми + в разделе профилей. Можно вставить ссылку вручную, из буфера или отсканировать QR.',
      ),
      _FaqItem(
        question: 'Какие протоколы поддерживаются?',
        answer:
            'Поддерживаются VLESS Reality, VLESS TLS, NaiveProxy, Hysteria2, Hysteria, Remnawave подписки и sing-box JSON.',
      ),
      _FaqItem(
        question: 'Что делать, если после смены профиля пропал интернет?',
        answer:
            'Нажми Отключить, подожди статус Остановлено и подключи профиль снова. Если проблема повторяется, отправь отчёт разработчику.',
      ),
      _FaqItem(
        question: 'Почему нужна шторка уведомления?',
        answer:
            'Android требует постоянное уведомление для VPN. Разреши уведомления, чтобы видеть статус и скорость в шторке.',
      ),
      _FaqItem(
        question: 'Почему теперь лучше работает мобильная сеть?',
        answer:
            'Приложение использует единый сетевой режим для Wi‑Fi и LTE: DNS сервера VPN, аккуратное переподключение и устойчивую маршрутизацию через туннель.',
      ),
      _FaqItem(
        question: 'Безопасно ли отправлять отчёт?',
        answer:
            'Отчёт открывается в твоей почте перед отправкой. Пароли, UUID и ключи скрываются автоматически.',
      ),
    ],
    logs: 'Логи sing-box',
    noLogs: 'Логов пока нет.',
    notificationDescription: 'VPN подключение активно',
  );

  static const en = _Strings._(
    addProfileHint: 'Add a Remnawave subscription, QR code, or single key',
    nothingToImport: 'Nothing to import.',
    switchingProfile: 'Switching profile...',
    importFirst: 'Import a profile first.',
    configSaveFailed: 'sing-box did not save the config.',
    vpnStartFailed: 'VPN did not start. Check the logs below.',
    connectionProbeFailed:
        'VPN started, but the tunnel internet probe did not pass.',
    disconnectingVpn: 'Disconnecting VPN...',
    vpnStopServiceFailed: 'VPN service could not fully stop.',
    vpnStopped: 'VPN stopped',
    profileDeleted: 'Profile deleted',
    linkCopied: 'Link copied',
    close: 'Close',
    working: 'Working...',
    report: 'Report',
    cannotOpenLink: 'Could not open the link.',
    mailSubject: 'Yurich Connect: VPN diagnostics',
    mailFallback: 'Mail did not open. Report copied to clipboard.',
    vpnStoppedUnexpectedly: 'VPN stopped unexpectedly',
    openLogsMessage: 'VPN stopped. Open sing-box logs.',
    languageChanged: 'Language changed',
    addProfile: 'Add profile',
    importHint:
        'https://sub... or vless://... or naive+https://... or hy2://...',
    importAction: 'Import',
    clipboard: 'Clipboard',
    scanQr: 'Scan QR',
    pasteFromClipboard: 'Paste from clipboard',
    language: 'Language',
    connected: 'Connected',
    connectionProblem: 'Connection problem',
    connecting: 'Connecting',
    disconnecting: 'Disconnecting',
    stopped: 'Stopped',
    profiles: 'Profiles',
    refreshPing: 'Refresh ping',
    showQr: 'Show QR',
    copy: 'Copy',
    delete: 'Delete',
    emptyProfiles: 'No profiles yet. Tap +, paste a subscription, or scan QR.',
    profileInsight: 'Profile and network',
    profileInsightEmpty:
        'Select a profile to see connection parameters and recommendations.',
    protocolLabel: 'Protocol',
    networkLabel: 'Network',
    dnsLabel: 'DNS',
    dnsCountryValue: 'Through profile',
    stabilityLabel: 'Stability',
    stabilityValue: 'Background keeper',
    countryLabel: 'Country',
    pingLabel: 'Ping',
    subscriptionLabel: 'Subscription',
    subscriptionUnknown: 'Not provided',
    subscriptionExpired: 'Expired',
    refreshSubscriptions: 'Refresh subscriptions',
    refreshingSubscriptions: 'Refreshing subscriptions...',
    noSubscriptionsToRefresh:
        'No saved subscription source. Paste the https://.../links.txt URL once.',
    subscriptionReminderTitle: 'Subscription renewal',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Wi-Fi/LTE: strict TUN, FakeIP, DNS through the selected profile, and a background keeper that checks the tunnel without opening the app.',
    androidVpnVisibleNote:
        'Android can expose VPN status to apps. Yurich Connect protects IP/DNS, but system VpnService cannot be hidden without root/custom firmware.',
    endpointLabel: 'Server',
    connect: 'Connect',
    disconnect: 'Disconnect',
    contact: 'Contact',
    support: 'Support',
    donate: 'Donate',
    developer: 'Developer',
    updates: 'Updates',
    updateDescription:
        'The app checks for a fresh APK, picks the right file for this phone, and opens the Android installer. No release page is opened.',
    updateChannel: 'Update channel: GitHub Releases',
    checkUpdates: 'Check and install',
    updateChecking: 'Checking updates...',
    updateInstallerOpened: 'Android installer opened',
    updateInstallPermission:
        'Allow app installs from Yurich Connect, then press the button again.',
    openSettings: 'Settings',
    faq: 'FAQ',
    faqItems: [
      _FaqItem(
        question: 'How do I add a subscription or key?',
        answer:
            'Use the add button in Profiles. You can paste manually, import from clipboard, or scan a QR code.',
      ),
      _FaqItem(
        question: 'Which protocols are supported?',
        answer:
            'VLESS Reality, VLESS TLS, NaiveProxy, Hysteria2, Hysteria, Remnawave subscriptions, and sing-box JSON are supported.',
      ),
      _FaqItem(
        question: 'What if internet stops after switching profiles?',
        answer:
            'Tap Disconnect, wait for Stopped, then connect again. If it repeats, send a developer report.',
      ),
      _FaqItem(
        question: 'Why does Android need a notification?',
        answer:
            'Android requires a persistent notification for VPN. Allow notifications to see status and speed in the shade.',
      ),
      _FaqItem(
        question: 'Why should mobile networks work better now?',
        answer:
            'The app uses one network baseline for Wi‑Fi and LTE: VPN server DNS, smoother reconnects, and stable tunnel routing.',
      ),
      _FaqItem(
        question: 'Is sending a report safe?',
        answer:
            'The report opens in your email before sending. Passwords, UUIDs, and keys are hidden automatically.',
      ),
    ],
    logs: 'sing-box logs',
    noLogs: 'No logs yet.',
    notificationDescription: 'VPN connection is active',
  );
}
