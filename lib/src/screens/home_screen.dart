import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/vpn_profile.dart';
import '../services/app_update_service.dart';
import '../services/profile_importer.dart';
import '../services/profile_store.dart';
import '../services/sing_box_config_builder.dart';
import '../services/vpn_engine.dart';
import 'qr_scan_screen.dart';

const _gold = Color(0xFFD9A441);
const _goldSoft = Color(0xFFFFE6A3);
const _ink = Color(0xFF0E0B07);
const _surface = Color(0xFF18130B);
const _surfaceMetric = Color(0xFF2D2110);
const _mutedGold = Color(0xFFB9AA86);
const _appName = 'Aurum VPN';
const _telegramUrl = 'https://t.me/ivan_it_net';
const _vkUrl = 'https://vk.com/ivan_yurievich_it';
const _donateUrl = 'https://dzen.ru/ivanyurievich?donate=true';
const _supportEmail = 'ai@ivan-it.net';
const _appVersion = '1.0.24';

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
  final _manualController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _statusSubscription;
  StreamSubscription<Map<String, dynamic>>? _trafficSubscription;
  StreamSubscription<Map<String, dynamic>>? _logSubscription;
  Timer? _logFlushTimer;
  Timer? _statusWatchdogTimer;
  DateTime? _ignoreStoppedUntil;

  List<VpnProfile> _profiles = const [];
  String? _selectedProfileId;
  _AppLanguage _language = _AppLanguage.ru;
  String _status = AurumVpnStatus.stopped;
  String _uplink = '0 B/s';
  String _downlink = '0 B/s';
  String _sessionTotal = '0 B';
  String _message = 'Готов к импорту подписки';
  String? _lastError;
  bool _busy = false;
  bool _updateBusy = false;
  bool _stoppingByUser = false;
  bool _logsExpanded = false;
  String? _lastConfigSummary;
  String? _updateMessage;
  double? _updateProgress;
  final _logs = <String>[];
  final _pendingLogs = <String>[];

  _Strings get s => _Strings.forLanguage(_language);

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

  @override
  void initState() {
    super.initState();
    _load();
    _initVpn();
    _statusWatchdogTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_refreshStatusWatchdog()),
    );
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _trafficSubscription?.cancel();
    _logSubscription?.cancel();
    _logFlushTimer?.cancel();
    _statusWatchdogTimer?.cancel();
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
        setState(() {
          _status = status;
          if (status == AurumVpnStatus.started) {
            _lastError = null;
            _ignoreStoppedUntil = DateTime.now().add(
              const Duration(seconds: 4),
            );
          }
          final ignoreStopped =
              _ignoreStoppedUntil != null &&
              DateTime.now().isBefore(_ignoreStoppedUntil!);
          if (status == AurumVpnStatus.stopped &&
              !_stoppingByUser &&
              !ignoreStopped) {
            _lastError = s.vpnStoppedUnexpectedly;
            _message = s.openLogsMessage;
          }
        });
      }
    });

    _trafficSubscription = _vpnEngine.onTrafficUpdate.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        _uplink = event['formattedUplinkSpeed'] as String? ?? _uplink;
        _downlink = event['formattedDownlinkSpeed'] as String? ?? _downlink;
        _sessionTotal =
            event['formattedSessionTotal'] as String? ?? _sessionTotal;
      });
    });

    try {
      await _vpnEngine.setNotificationTitle(_appName);
      await _vpnEngine.setNotificationDescription(s.notificationDescription);
      await _vpnEngine.requestNotificationPermission();
      final status = await _vpnEngine.getVPNStatus();
      final bufferedLogs = await _vpnEngine.getLogs();
      if (mounted) {
        setState(() {
          _status = status;
          _logs
            ..clear()
            ..addAll(
              bufferedLogs
                  .map(_cleanLog)
                  .where((log) => log.isNotEmpty)
                  .toList()
                  .reversed
                  .take(60)
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

      final merged = <String, VpnProfile>{
        for (final profile in _profiles) profile.id: profile,
        for (final profile in imported) profile.id: profile,
      }.values.toList();

      await _store.saveProfiles(merged);
      await _store.saveSelectedProfileId(imported.first.id);
      _manualController.clear();

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = merged;
        _selectedProfileId = imported.first.id;
        _message = s.imported(imported.length);
      });
      _showSnack(s.importedProfiles(imported.length));
    });
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

    await _runBusy(
      () => _startVpnCore(profile),
      message: s.connectingTo(profile.name),
    );
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
    await _vpnEngine.clearLogs();

    await _vpnEngine.requestNotificationPermission();

    Object? lastStartError;
    var connected = false;
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
      final saved = await _vpnEngine.saveConfig(config);
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

        final started = await _vpnEngine.startVPN();
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
              lastStartError = s.connectionProbeFailed;
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
          await _vpnEngine.saveConfig(config);
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
        _message = s.connectionProfile(profile.name);
      });
    }
  }

  Future<void> _disconnect() async {
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
          onTimeout: () => true,
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
      final status = await _vpnEngine.getVPNStatus();
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
    if (!mounted || _busy) {
      return;
    }

    final previous = _status;
    final status = await _refreshVpnStatus();
    final ignoreStopped =
        _ignoreStoppedUntil != null &&
        DateTime.now().isBefore(_ignoreStoppedUntil!);
    if (previous == AurumVpnStatus.started &&
        status == AurumVpnStatus.stopped &&
        !_stoppingByUser &&
        !ignoreStopped &&
        mounted) {
      setState(() {
        _lastError = s.vpnStoppedUnexpectedly;
        _message = s.openLogsMessage;
      });
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

  Future<bool> _probeLocalMixedProxy() async {
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

    for (var attempt = 1; attempt <= 2; attempt += 1) {
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
            'AurumVPN/$_appVersion',
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
          _queueLog(
            'VPN health probe HTTP ${response.statusCode}: ${endpoint.uri}',
          );
        } on Object catch (error) {
          _queueLog('VPN health probe failed: ${_redactSensitive('$error')}');
        } finally {
          client.close(force: true);
        }
      }

      if (attempt == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }

    return false;
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
      await _vpnEngine.setNotificationDescription(
        strings.notificationDescription,
      );
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

  Future<void> _deleteSelected() async {
    final selected = _selectedProfile;
    if (selected == null) {
      return;
    }

    final next = _profiles
        .where((profile) => profile.id != selected.id)
        .toList();
    await _store.saveProfiles(next);
    await _store.saveSelectedProfileId(next.isEmpty ? null : next.first.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _profiles = next;
      _selectedProfileId = next.isEmpty ? null : next.first.id;
      _message = s.profileDeleted;
    });
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
    final lines = <String>[
      '$_appName diagnostic',
      'app_version: $_appVersion',
      'config_target: ${_vpnEngine.configTarget.name}',
      if (_lastConfigSummary != null) 'config: $_lastConfigSummary',
      'status: $_status',
      'message: ${_redactSensitive(_message)}',
      if (_lastError != null) 'last_error: $_lastError',
      if (profile != null) ...[
        'profile: ${_redactSensitive(profile.name)}',
        'protocol: ${_profileKindLabel(profile.kind)}',
        'endpoint: ${_redactSensitive(profile.endpoint)}',
      ],
      'traffic: up=$_uplink down=$_downlink total=$_sessionTotal',
      '',
      'logs:',
    ];

    final safeLogs = _logs
        .take(_logs.length)
        .toList()
        .reversed
        .take(35)
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
    if (_pendingLogs.length > 120) {
      _pendingLogs.removeRange(0, _pendingLogs.length - 120);
    }

    _logFlushTimer ??= Timer(const Duration(milliseconds: 250), () {
      _logFlushTimer = null;
      if (!mounted || _pendingLogs.isEmpty) {
        return;
      }

      setState(() {
        _logs.addAll(_pendingLogs);
        _pendingLogs.clear();
        if (_logs.length > 60) {
          _logs.removeRange(0, _logs.length - 60);
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
            CircleAvatar(
              radius: 17,
              backgroundImage: AssetImage('assets/images/app_icon.png'),
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
              message: _message,
              uplink: _uplink,
              downlink: _downlink,
              sessionTotal: _sessionTotal,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy || selected == null ? null : _toggleVpn,
              icon: Icon(_connected ? Icons.power_settings_new : Icons.shield),
              label: Text(_connected ? s.disconnect : s.connect),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                textStyle: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 16),
            _ProfilePanel(
              strings: s,
              profiles: _profiles,
              selectedProfile: selected,
              selectedId: selected?.id,
              onSelect: _selectProfile,
              onAdd: _showImportSheet,
              onCopy: selected == null ? null : _copySelected,
              onQr: selected == null ? null : _showQr,
              onDelete: selected == null ? null : _deleteSelected,
              kindLabel: _profileKindLabel,
            ),
            const SizedBox(height: 16),
            _SupportPanel(
              strings: s,
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
    required this.message,
    required this.uplink,
    required this.downlink,
    required this.sessionTotal,
  });

  final _Strings strings;
  final String status;
  final String message;
  final String uplink;
  final String downlink;
  final String sessionTotal;

  @override
  Widget build(BuildContext context) {
    final connected = status == AurumVpnStatus.started;
    final statusLabel = switch (status) {
      AurumVpnStatus.started => strings.connected,
      AurumVpnStatus.starting => strings.connecting,
      AurumVpnStatus.stopping => strings.disconnecting,
      _ => strings.stopped,
    };

    return SizedBox(
      height: 188,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: connected ? _gold : Colors.white12),
          boxShadow: [
            BoxShadow(
              color: connected ? _gold.withValues(alpha: 0.18) : Colors.black26,
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
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
                    connected ? Icons.verified_user : Icons.shield_outlined,
                    color: connected ? _goldSoft : _mutedGold,
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
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _Metric(label: '↑', value: uplink, fixed: true),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(label: '↓', value: downlink, fixed: true),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(
                      label: 'Σ',
                      value: sessionTotal,
                      fixed: true,
                    ),
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
      height: fixed ? 48 : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _surfaceMetric,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
      ),
      alignment: Alignment.centerLeft,
      child: fixed
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
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
    required this.onSelect,
    required this.onAdd,
    required this.onCopy,
    required this.onQr,
    required this.onDelete,
    required this.kindLabel,
  });

  final _Strings strings;
  final List<VpnProfile> profiles;
  final VpnProfile? selectedProfile;
  final String? selectedId;
  final ValueChanged<VpnProfile> onSelect;
  final VoidCallback onAdd;
  final VoidCallback? onCopy;
  final VoidCallback? onQr;
  final VoidCallback? onDelete;
  final String Function(VpnProfileKind kind) kindLabel;

  @override
  Widget build(BuildContext context) {
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
            IconButton(
              tooltip: strings.delete,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (profiles.isEmpty)
          _EmptyProfiles(strings: strings)
        else
          ...profiles.map(
            (profile) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProfileTile(
                profile: profile,
                selected: profile.id == selectedId,
                onTap: () => onSelect(profile),
                kindLabel: kindLabel,
              ),
            ),
          ),
        const SizedBox(height: 6),
        _ProfileInsightPanel(
          strings: strings,
          profile: selectedProfile,
          kindLabel: kindLabel,
        ),
      ],
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.selected,
    required this.onTap,
    required this.kindLabel,
  });

  final VpnProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final String Function(VpnProfileKind kind) kindLabel;

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
            Icon(switch (profile.kind) {
              VpnProfileKind.naive => Icons.public,
              VpnProfileKind.hysteria2 ||
              VpnProfileKind.hysteria => Icons.speed_outlined,
              _ => Icons.bolt,
            }, color: selected ? _goldSoft : _mutedGold),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({required this.strings});

  final _Strings strings;

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
      child: Text(strings.emptyProfiles),
    );
  }
}

class _ProfileInsightPanel extends StatelessWidget {
  const _ProfileInsightPanel({
    required this.strings,
    required this.profile,
    required this.kindLabel,
  });

  final _Strings strings;
  final VpnProfile? profile;
  final String Function(VpnProfileKind kind) kindLabel;

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
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _Metric(
                        label: strings.protocolLabel,
                        value: kindLabel(profile!.kind),
                      ),
                      _Metric(
                        label: strings.networkLabel,
                        value: strings.mobileReady,
                      ),
                      _Metric(
                        label: strings.dnsLabel,
                        value: strings.dnsCountryValue,
                      ),
                      _Metric(
                        label: strings.subscriptionLabel,
                        value: strings.subscriptionStatus(
                          profile!.subscriptionExpiresAt,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    strings.mobileNetworkAdvice,
                    style: const TextStyle(color: _mutedGold, height: 1.35),
                  ),
                  const SizedBox(height: 8),
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

class _SupportPanel extends StatelessWidget {
  const _SupportPanel({
    required this.strings,
    required this.language,
    required this.onLanguageChanged,
    required this.onSupport,
    required this.onTelegram,
    required this.onVk,
    required this.onDonate,
    required this.onDeveloper,
  });

  final _Strings strings;
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
        Text(strings.contact, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: onSupport,
              icon: const Icon(Icons.support_agent),
              label: Text(strings.support),
            ),
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
            OutlinedButton.icon(
              onPressed: onDeveloper,
              icon: const Icon(Icons.mail_outline),
              label: Text(strings.developer),
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
    required this.connecting,
    required this.disconnecting,
    required this.stopped,
    required this.profiles,
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
    required this.subscriptionLabel,
    required this.subscriptionUnknown,
    required this.subscriptionExpired,
    required this.mobileReady,
    required this.mobileNetworkAdvice,
    required this.endpointLabel,
    required this.connect,
    required this.disconnect,
    required this.contact,
    required this.support,
    required this.donate,
    required this.developer,
    required this.updates,
    required this.updateDescription,
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
  final String connecting;
  final String disconnecting;
  final String stopped;
  final String profiles;
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
  final String subscriptionLabel;
  final String subscriptionUnknown;
  final String subscriptionExpired;
  final String mobileReady;
  final String mobileNetworkAdvice;
  final String endpointLabel;
  final String connect;
  final String disconnect;
  final String contact;
  final String support;
  final String donate;
  final String developer;
  final String updates;
  final String updateDescription;
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
    mailSubject: 'Aurum VPN: диагностика VPN',
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
    connecting: 'Подключаюсь',
    disconnecting: 'Отключаюсь',
    stopped: 'Остановлено',
    profiles: 'Профили',
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
    dnsCountryValue: 'Защищённый DNS',
    subscriptionLabel: 'Подписка',
    subscriptionUnknown: 'Срок не указан',
    subscriptionExpired: 'Истекла',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'Подключение настроено для стабильной работы в Wi‑Fi и мобильных сетях. DNS-запросы идут через туннель, а при смене профиля приложение полностью пересобирает конфиг.',
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
    checkUpdates: 'Проверить и установить',
    updateChecking: 'Проверяю обновления...',
    updateInstallerOpened: 'Установщик Android открыт',
    updateInstallPermission:
        'Разреши установку приложений из Aurum VPN и нажми кнопку ещё раз.',
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
            'Приложение использует единый сетевой режим для Wi‑Fi и LTE: защищённый DNS, аккуратное переподключение и устойчивую маршрутизацию через туннель.',
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
    mailSubject: 'Aurum VPN: VPN diagnostics',
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
    connecting: 'Connecting',
    disconnecting: 'Disconnecting',
    stopped: 'Stopped',
    profiles: 'Profiles',
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
    dnsCountryValue: 'Protected DNS',
    subscriptionLabel: 'Subscription',
    subscriptionUnknown: 'Not provided',
    subscriptionExpired: 'Expired',
    mobileReady: 'Wi‑Fi / LTE',
    mobileNetworkAdvice:
        'The connection is tuned for stable Wi‑Fi and mobile networks. DNS requests stay inside the tunnel, and the app rebuilds the config when switching profiles.',
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
    checkUpdates: 'Check and install',
    updateChecking: 'Checking updates...',
    updateInstallerOpened: 'Android installer opened',
    updateInstallPermission:
        'Allow app installs from Aurum VPN, then press the button again.',
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
            'The app uses one network baseline for Wi‑Fi and LTE: protected DNS, smoother reconnects, and stable tunnel routing.',
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
