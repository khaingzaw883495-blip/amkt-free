import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/vpn_server.dart';
import '../services/ad_config.dart';
import '../services/app_store.dart';
import '../services/app_update.dart';
import '../services/buyer_servers.dart';
import '../services/home_widget_service.dart';
import '../services/network_tools.dart';
import '../services/notifications.dart';
import '../services/per_app_vpn.dart';
import '../services/subscription_service.dart';
import '../services/time_credit.dart';
import '../services/vpn_engine.dart';
import '../widgets/ad_banner.dart';
import '../widgets/interstitial_ad.dart';
import '../widgets/update_dialog.dart';
import 'settings_page.dart';

/// Main screen (v1.0.10) — two bottom tabs: VPN / Settings.
///
/// Server selection now lives right on the VPN tab via a modal bottom sheet
/// opened by tapping the country/server card (with search, ping, auto-fastest,
/// frequent servers on top, and instant server switching for VIP/paid users).
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  AppStore? _store;
  TimeCreditService? _timeCredit;
  bool _loading = true;
  bool _refreshing = false;

  /// Bottom tab: 0 = VPN, 1 = Settings (Servers tab removed in v1.0.10).
  int _tabIndex = 0;

  /// server id -> TCP-connect latency in ms (null = failed);
  /// absent = not measured yet.
  final Map<String, int?> _pings = {};
  DateTime? _lastPingAt;

  /// Post-connect public IP + country info.
  IpInfo? _ipInfo;
  bool _ipLoading = false;

  /// Cumulative data usage + connection history session tracking.
  StreamSubscription<VpnState>? _stateSub;
  StreamSubscription<VpnStats>? _statsSub;
  StreamSubscription<Uri?>? _widgetClickSub;

  VpnServer? _activeSessionServer;
  DateTime? _activeSessionStart;
  int _sessionLastReportedBytes = 0;
  int _sessionBufferedDelta = 0;

  bool _updateDialogShown = false;
  bool _timeExpiredDialogShown = false;
  DateTime? _lastWidgetToggleAt;

  @override
  void initState() {
    super.initState();
    _load();
    _stateSub = VpnEngine.instance.stateStream.listen(_onVpnStateChanged);
    _statsSub = VpnEngine.instance.statsStream.listen(_onVpnStats);
    _widgetClickSub = HomeWidget.widgetClicked.listen(_handleWidgetUri);
  }

  void _onVpnStateChanged(VpnState state) {
    if (mounted) setState(() {});
    final store = _store;
    final engine = VpnEngine.instance;
    final current = engine.currentServer ?? store?.selectedServer;
    unawaited(HomeWidgetService.update(state, current));

    if (state == VpnState.connected) {
      // Start tracking this session for history & frequent servers.
      final srv = engine.currentServer;
      if (srv != null && _activeSessionServer?.id != srv.id) {
        _activeSessionServer = srv;
        _activeSessionStart = DateTime.now();
        _sessionLastReportedBytes = 0;
        _sessionBufferedDelta = 0;
        if (store != null) {
          unawaited(store.recordServerUse(srv.id));
        }
      }
      // Fetch public IP + country after connect.
      unawaited(_fetchConnectedIp());
    } else if (state == VpnState.disconnected || state == VpnState.error) {
      // Flush session usage + record connection history.
      unawaited(_finalizeSession());
      if (mounted && (_ipInfo != null || _ipLoading)) {
        setState(() {
          _ipInfo = null;
          _ipLoading = false;
        });
      }
    }

    final credit = _timeCredit;
    if (store == null || credit == null) return;
    if (state == VpnState.connected &&
        !store.hidesAdsFor(engine.currentServer)) {
      credit.startCountdown(onExpired: _onTimeCreditExpired);
    } else {
      credit.stopCountdown();
    }
  }

  void _onVpnStats(VpnStats stats) {
    final store = _store;
    if (store == null || !VpnEngine.instance.isConnected) return;
    final currentTotal = stats.upTotal + stats.downTotal;
    if (currentTotal < _sessionLastReportedBytes) {
      // Counter reset on reconnect
      _sessionLastReportedBytes = currentTotal;
      return;
    }
    final delta = currentTotal - _sessionLastReportedBytes;
    _sessionLastReportedBytes = currentTotal;
    if (delta > 0) {
      _sessionBufferedDelta += delta;
      // Flush to SharedPreferences in >= 256 KB chunks to avoid disk churn.
      if (_sessionBufferedDelta >= 256 * 1024) {
        final toFlush = _sessionBufferedDelta;
        _sessionBufferedDelta = 0;
        unawaited(store.addTotalDataBytes(toFlush).then((_) {
          if (mounted) setState(() {});
        }));
      }
    }
  }

  Future<void> _finalizeSession() async {
    final store = _store;
    if (store == null) return;
    if (_sessionBufferedDelta > 0) {
      final toFlush = _sessionBufferedDelta;
      _sessionBufferedDelta = 0;
      await store.addTotalDataBytes(toFlush);
    }
    final srv = _activeSessionServer;
    final start = _activeSessionStart;
    final bytes = _sessionLastReportedBytes;
    _activeSessionServer = null;
    _activeSessionStart = null;
    _sessionLastReportedBytes = 0;
    if (srv != null && start != null) {
      final now = DateTime.now();
      final duration = now.difference(start).inSeconds;
      if (duration >= 1) {
        await store.addConnectionHistory(
          ConnectionHistoryEntry(
            serverName: _serverDisplayName(store, srv),
            countryCode: srv.countryCode,
            countryFlag: srv.countryFlag,
            countryName: srv.countryName,
            protocol: srv.protocol.label,
            connectedAt: start,
            disconnectedAt: now,
            durationSeconds: duration,
            dataBytes: bytes,
          ),
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _fetchConnectedIp() async {
    if (!mounted) return;
    setState(() {
      _ipLoading = true;
      _ipInfo = null;
    });
    // Small delay so the new tunnel routes are ready.
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted || !VpnEngine.instance.isConnected) return;
    final info = await NetworkToolsService.fetchPublicIp();
    if (!mounted || !VpnEngine.instance.isConnected) return;
    setState(() {
      _ipInfo = info;
      _ipLoading = false;
    });
  }

  Future<void> _onTimeCreditExpired() async {
    if (_timeExpiredDialogShown) return;
    _timeExpiredDialogShown = true;
    await VpnEngine.instance.disconnect().catchError((_) {});
    if (!mounted) return;
    final extended = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('အချိန်ကုန်သွားပြီ'),
        content: const Text(
          'Free အချိန် ၆ နာရီ ကုန်သွားပြီမို့ VPN ဖြုတ်လိုက်ပါတယ်။\n\nAdd Time နှိပ်ပြီး ၉ နာရီ ထပ်တိုးလို့ရပါတယ် (တစ်ရက် ၂ ခါ)။ ကုတ် ဝယ်ထားရင် အချိန် ကန့်သတ်ချက် မရှိပါ။',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('ရပြီ'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add Time'),
          ),
        ],
      ),
    );
    _timeExpiredDialogShown = false;
    if (extended == true && mounted) {
      await _showAddTimeDialog();
    }
  }

  Future<bool> _showAddTimeDialog() async {
    final credit = _timeCredit;
    if (credit == null) return false;
    await launchUrl(Uri.parse(AdConfigService.current.adLink),
            mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!mounted) return false;
    final added = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddTimeDialog(credit: credit),
    );
    if (added == true && mounted) {
      _snack('အချိန် ၉ နာရီ တိုးပြီးပြီ');
      setState(() {});
    }
    return added ?? false;
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _statsSub?.cancel();
    _widgetClickSub?.cancel();
    _timeCredit?.dispose();
    super.dispose();
  }

  void _handleWidgetUri(Uri? uri) {
    if (uri == null) return;
    if (uri.scheme != 'amktvpn' ||
        (uri.host != 'toggle' && uri.path != '/toggle')) {
      return;
    }
    final now = DateTime.now();
    if (_lastWidgetToggleAt != null &&
        now.difference(_lastWidgetToggleAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastWidgetToggleAt = now;
    unawaited(_onConnectPressed());
  }

  Future<void> _load() async {
    final store = await AppStore.load();
    final credit = await TimeCreditService.load();
    if (!mounted) return;
    setState(() {
      _store = store;
      _timeCredit = credit;
      _loading = false;
    });
    final launchedUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (mounted && launchedUri != null) _handleWidgetUri(launchedUri);
    unawaited(_refreshAll(silent: true));
    unawaited(_checkUpdate());
    unawaited(HomeWidgetService.update(
        VpnEngine.instance.state, store.selectedServer));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _onNoAdsChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_refreshAll(silent: true));
  }

  Future<void> _refreshAll({bool silent = false}) async {
    final store = _store;
    if (store == null || _refreshing) return;
    setState(() => _refreshing = true);
    var total = 0;
    final failed = <String>[];
    for (final sub in store.subscriptions) {
      if (sub.id != AppStore.freeSubId) continue;
      try {
        final servers = await SubscriptionService.fetchFreeServers();
        await store.saveServers(AppStore.freeSubId, servers);
        total += servers.length;
      } catch (_) {
        failed.add(sub.label);
      }
    }
    for (final sub in store.subscriptions) {
      if (sub.id == AppStore.freeSubId) continue;
      try {
        final fetch = await SubscriptionService.fetchWithInfo(sub.url,
            subscriptionId: sub.id);
        if (fetch.servers.isNotEmpty) {
          await store.saveServers(sub.id, fetch.servers);
        }
        await store.saveUserInfo(sub.id, fetch.userinfo);
      } catch (_) {}
    }
    final selectedBefore = store.selectedServer;
    if (store.hasNoAdsAccess) {
      await BuyerServersService.refreshBuyerServers(store);
      if (selectedBefore != null &&
          selectedBefore.subscriptionId == AppStore.buyerSubId &&
          !VpnEngine.instance.isConnected) {
        final freshIds = (store.serversCache[AppStore.buyerSubId] ?? [])
            .map((s) => s.id)
            .toSet();
        if (!freshIds.contains(selectedBefore.id)) {
          await store.setSelectedServerId(null);
          if (mounted && !silent) {
            _snack('Premium Servers လဲသွားပြီ — server အသစ် ရွေးပါ');
          }
        }
      }
    }
    if (mounted) {
      setState(() => _refreshing = false);
      if (!silent) {
        _snack(failed.isEmpty
            ? 'Server $total ခု ရပြီ'
            : 'တချို့ subscription ဆွဲမရပါ: ${failed.join(', ')}');
      }
    }
    unawaited(NotificationService.refreshReminders(store));
    await _measurePings();
    // Auto-pick fastest server on first launch if none is selected yet.
    if (store.selectedServer == null &&
        store.allServers.isNotEmpty &&
        !VpnEngine.instance.isConnected) {
      await _autoPickFastestIfUnselected(store);
    }
    unawaited(HomeWidgetService.update(
        VpnEngine.instance.state, store.selectedServer));
  }

  Future<void> _autoPickFastestIfUnselected(AppStore store) async {
    VpnServer? best;
    int? bestPing;
    for (final s in store.allServers) {
      if (!s.canConnect) continue;
      final p = _pings[s.id];
      if (p == null) continue;
      if (bestPing == null || p < bestPing) {
        bestPing = p;
        best = s;
      }
    }
    best ??= store.allServers.where((s) => s.canConnect).firstOrNull;
    if (best != null) {
      await store.setSelectedServerId(best.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _measurePings({bool force = false}) async {
    final store = _store;
    if (store == null) return;
    final last = _lastPingAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return;
    }
    final servers = store.allServers;
    if (servers.isEmpty) return;
    const batchSize = 6;
    for (var i = 0; i < servers.length; i += batchSize) {
      final batch = servers.skip(i).take(batchSize);
      final results = await Future.wait(
        batch.map<Future<MapEntry<String, int?>>>((s) async {
          try {
            final sw = Stopwatch()..start();
            final sock = await Socket.connect(s.address, s.port,
                timeout: const Duration(seconds: 3));
            sw.stop();
            sock.destroy();
            return MapEntry(s.id, sw.elapsedMilliseconds);
          } catch (_) {
            return MapEntry<String, int?>(s.id, null);
          }
        }),
      );
      if (!mounted) return;
      setState(() {
        for (final e in results) {
          _pings[e.key] = e.value;
        }
        _lastPingAt = DateTime.now();
      });
    }
  }

  Future<void> _pickFastest() async {
    final store = _store;
    if (store == null) return;
    final connected = VpnEngine.instance.isConnected;
    if (connected && !store.hasPaidAccess) {
      _snack('အရင် Disconnect လုပ်ပါ');
      return;
    }
    _snack('အမြန်ဆုံး ဆာဗာ ရှာနေတယ်…');
    await _measurePings(force: true);
    VpnServer? best;
    int? bestPing;
    for (final s in store.allServers) {
      if (!s.canConnect) continue;
      final p = _pings[s.id];
      if (p == null) continue;
      if (bestPing == null || p < bestPing) {
        bestPing = p;
        best = s;
      }
    }
    if (best == null) {
      _snack('ping စစ်မရပါ — ဆာဗာ တစ်ခုခု ရွေးပါ');
      return;
    }
    await _selectServer(best);
    _snack(
        'အမြန်ဆုံး ရွေးပြီးပြီ — ${best.countryFlag} ${best.countryName} ($bestPing ms)');
  }

  Future<void> _checkUpdate() async {
    if (_updateDialogShown) return;
    final info = await AppUpdateService.checkForUpdate();
    if (info == null || !mounted) return;
    _updateDialogShown = true;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  Future<void> _onConnectPressed() async {
    final engine = VpnEngine.instance;
    final store = _store;
    if (store == null) return;
    if (engine.isConnected || engine.state == VpnState.connecting) {
      await engine.disconnect().catchError((_) {});
      return;
    }
    var server = store.selectedServer;
    if (server == null) {
      _showServerPickerSheet(store);
      return;
    }
    if (!server.canConnect) {
      _snack('${server.protocol.label} ချိတ်ဆက်မှု မကြာမီ ရမယ်');
      return;
    }
    final credit = _timeCredit;
    if (!store.hidesAdsFor(server) &&
        credit != null &&
        credit.remainingSeconds <= 0) {
      await _showAddTimeDialog();
      return;
    }
    if (!store.hidesAdsFor(server)) {
      final go = await showConnectAdGate(context);
      if (!go || !mounted) return;
    }
    try {
      await PerAppVpnService.applyStoredSelection(store);
      await engine.connect(server);
    } catch (e) {
      if (mounted) _snack('ချိတ်မရပါ: ${_shortError(e)}');
    }
  }

  String _shortError(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  /// Selects [server].
  /// v1.0.10: VIP / paid users (`store.hasPaidAccess` or `store.hidesAdsFor`)
  /// can switch servers INSTANTLY while already connected — no manual
  /// disconnect and no ad gate needed.
  Future<void> _selectServer(VpnServer server) async {
    final engine = VpnEngine.instance;
    final store = _store!;
    if (!server.canConnect) {
      _snack('${server.protocol.label} ချိတ်ဆက်မှု မကြာမီ ရမယ်');
      return;
    }
    if (engine.isConnected || engine.state == VpnState.connecting) {
      // Same server already active — nothing to do.
      if (engine.currentServer?.id == server.id) return;
      final canInstantSwitch =
          store.hasPaidAccess || store.hidesAdsFor(server);
      if (!canInstantSwitch) {
        _snack('အရင် Disconnect လုပ်ပါ');
        return;
      }
      // VIP instant server switch!
      await _finalizeSession();
      await store.setSelectedServerId(server.id);
      if (mounted) setState(() {});
      _snack(
          'ဆာဗာ ပြောင်းချိတ်နေတယ် — ${server.countryFlag} ${_serverDisplayName(store, server)}');
      try {
        await PerAppVpnService.applyStoredSelection(store);
        await engine.connect(server);
      } catch (e) {
        if (mounted) _snack('ပြောင်းချိတ်မရပါ: ${_shortError(e)}');
      }
      return;
    }
    await store.setSelectedServerId(server.id);
    if (mounted) setState(() {});
    unawaited(HomeWidgetService.update(engine.state, server));
  }

  Future<void> _toggleFavourite(VpnServer server) async {
    await _store!.toggleFavourite(server.id);
    if (mounted) setState(() {});
  }

  Future<void> _showBuyPremiumDialog() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Buy Premium'),
        content: const Text(
          'Premium Servers — ၃,၅၀၀ Ks/month\n\n• ကြော်ငြာ မပေါ်ဘူး\n• ၇ စက္ကန့် မစောင့်ရဘူး\n• VIP Server တွေ တန်းချိန်းသုံးနိုင်တယ်',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('code'),
            child: const Text('I have a code'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop('buy'),
            child: const Text('Buy via Telegram @mmoutlinekey_bot'),
          ),
        ],
      ),
    );
    if (action == 'buy') {
      await launchUrl(Uri.parse('https://t.me/mmoutlinekey_bot'),
              mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } else if (action == 'code' && mounted) {
      setState(() => _tabIndex = 1); // Settings tab (2 tabs total)
    }
  }

  Future<void> _confirmResetDataUsage() async {
    final store = _store;
    if (store == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ဒေတာ သုံးစွဲမှု Reset လုပ်မလား?'),
        content: const Text('စုစုပေါင်း ဒေတာသုံးစွဲမှုကို 0 ပြန်ချပါမယ်။'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('မလုပ်ဘူး'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _sessionBufferedDelta = 0;
      await store.resetTotalDataBytes();
      if (mounted) {
        setState(() {});
        _snack('ဒေတာ သုံးစွဲမှု Reset လုပ်ပြီးပြီ');
      }
    }
  }

  void _openSpeedtestDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SpeedtestDialog(),
    );
  }

  void _showServerPickerSheet(AppStore store) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _ServerPickerSheet(
        store: store,
        pings: _pings,
        refreshing: _refreshing,
        serverDisplayName: (s) => _serverDisplayName(store, s),
        onSelectServer: (s) async {
          Navigator.of(sheetContext).pop();
          await _selectServer(s);
        },
        onToggleFavourite: (s) async {
          await _toggleFavourite(s);
        },
        onPickFastest: () async {
          Navigator.of(sheetContext).pop();
          await _pickFastest();
        },
        onRefresh: () async {
          await _refreshAll();
        },
        onBuyPremium: () {
          Navigator.of(sheetContext).pop();
          _showBuyPremiumDialog();
        },
      ),
    );
  }

  String _serverDisplayName(AppStore store, VpnServer server) {
    if (server.subscriptionId != AppStore.buyerSubId) {
      final name = server.name;
      if (name.isNotEmpty &&
          name != '${server.address}:${server.port}' &&
          !_isIpv4(name) &&
          !name.contains('TG@amktvpn')) {
        return name;
      }
    }
    final servers = store.serversCache[server.subscriptionId] ?? [];
    final group =
        servers.where((s) => s.countryCode == server.countryCode).toList();
    final idx = group.indexWhere((s) => s.id == server.id);
    return 'Server ${idx >= 0 ? idx + 1 : 1}';
  }

  bool _isIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading || store == null) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? const [Color(0xFF1E1A3A), Color(0xFF0F0D1E)]
                  : const [Color(0xFFEAF4FF), Color(0xFFD6EAFF)],
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('AMKT VPN',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? const [Color(0xFF8B5CF6), Color(0xFF22D3EE)]
                      : const [Color(0xFF1D8FE1), Color(0xFF38BDF8)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.bolt, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Text('AMKT VPN',
                style: TextStyle(fontWeight: FontWeight.bold)),
            if (store.hasPaidAccess) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.6)),
                ),
                child: const Text(
                  'VIP',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.speed),
            tooltip: 'Speedtest စစ်မယ်',
            onPressed: _openSpeedtestDialog,
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildVpnTab(store),
          SettingsTab(
            store: store,
            onNoAdsChanged: _onNoAdsChanged,
            onDataUsageReset: () {
              _sessionBufferedDelta = 0;
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        bottom: true,
        child: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: (i) => setState(() => _tabIndex = i),
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.power_settings_new),
              label: 'VPN',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  /// VPN tab (v1.0.10):
  /// - Clean status + Connect button (no dark/black center box in Light mode!)
  /// - Post-connect IP + Country chip
  /// - Country/Server card -> opens Bottom Sheet server picker
  /// - Remaining GB + Expiry Date card (when available)
  /// - Total Data Usage + Reset + Speedtest quick actions
  /// - Time Left / Add Time (free users)
  /// - Ad banners
  Widget _buildVpnTab(AppStore store) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: [
        _buildStatusSection(store),
        const SizedBox(height: 14),
        _buildServerSelectorCard(store),
        const SizedBox(height: 12),
        _buildPlanInfoCard(store),
        _buildTotalUsageAndToolsRow(store),
        if (!store.hasPaidAccess) ...[
          const SizedBox(height: 12),
          _buildTimeLeftCard(),
        ],
        const SizedBox(height: 14),
        _buildBannerSlot(store),
      ],
    );
  }

  /// Status & Connect button.
  /// v1.0.10: In Light theme (အပြာနု), the dark/black center box is REMOVED —
  /// the connect button and status float cleanly on the light-blue canvas.
  Widget _buildStatusSection(AppStore store) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final engine = VpnEngine.instance;
    final state = engine.state;
    final connected = state == VpnState.connected;
    final connecting = state == VpnState.connecting;

    final connectGradient = connected
        ? const [Color(0xFF10B981), Color(0xFF059669)]
        : isDark
            ? const [Color(0xFF8B5CF6), Color(0xFF22D3EE)]
            : const [Color(0xFF1D8FE1), Color(0xFF38BDF8)];

    final glowColor = connected
        ? const Color(0xFF10B981)
        : isDark
            ? const Color(0xFF8B5CF6)
            : const Color(0xFF1D8FE1);

    final inner = Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: connected
                    ? Colors.green
                    : connecting
                        ? Colors.amber
                        : Colors.grey,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              connected
                  ? 'Connected'
                  : connecting
                      ? 'Connecting…'
                      : 'Not connected',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        if (connected) ...[
          const SizedBox(height: 8),
          _buildConnectedIpChip(isDark, muted),
          const SizedBox(height: 8),
          _speedRow(),
          const _TrafficPanel(),
        ],
        const SizedBox(height: 20),
        GestureDetector(
          onTap: _onConnectPressed,
          child: Container(
            width: 156,
            height: 156,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: connectGradient,
              ),
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(alpha: isDark ? 0.42 : 0.30),
                  blurRadius: 24,
                  spreadRadius: 2,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    connected ? Icons.power_settings_new : Icons.power,
                    size: 46,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    connecting
                        ? 'Connecting…'
                        : connected
                            ? 'TAP TO\nDISCONNECT'
                            : 'TAP TO\nCONNECT',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );

    // Light theme: NO dark/black center box! Clean open canvas.
    if (!isDark) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: inner,
      );
    }

    // Dark theme: keep the signature dark purple card.
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2350), Color(0xFF1E1A3A)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: inner,
    );
  }

  /// Post-connect public IP + country pill (Feature 7).
  Widget _buildConnectedIpChip(bool isDark, Color muted) {
    final chipBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.9);
    final chipBorder =
        isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFBFDBFE);

    return InkWell(
      onTap: _ipLoading ? null : _fetchConnectedIp,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: chipBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: chipBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_ipLoading) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('IP စစ်နေတယ်…', style: TextStyle(color: muted, fontSize: 12)),
            ] else if (_ipInfo != null) ...[
              Text(_ipInfo!.countryFlag, style: const TextStyle(fontSize: 15)),
              const SizedBox(width: 6),
              Text(
                '${_ipInfo!.ip} • ${_ipInfo!.country}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.refresh, size: 13, color: muted),
            ] else ...[
              Icon(Icons.public, size: 14, color: muted),
              const SizedBox(width: 6),
              Text('IP စစ်မယ်', style: TextStyle(color: muted, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  /// Country / Server selector card on the VPN tab (Feature 2).
  /// Tapping opens the bottom sheet server picker right on the first screen.
  Widget _buildServerSelectorCard(AppStore store) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final accent = Theme.of(context).colorScheme.primary;
    final selected = store.selectedServer;
    final ping = selected != null ? _pings[selected.id] : null;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _showServerPickerSheet(store),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Text(
                selected?.countryFlag ?? '🌐',
                style: const TextStyle(fontSize: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: selected != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _serverDisplayName(store, selected),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${selected.countryName} • ${selected.protocol.label}'
                            '${ping != null ? ' • $ping ms' : ''}',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ဆာဗာ ရွေးပါ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            'နိုင်ငံနဲ့ ဆာဗာ ရွေးရန် ဒီနေရာကို နှိပ်ပါ',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
              ),
              if (ping != null) ...[
                _signalBars(ping, isDark),
                const SizedBox(width: 8),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      store.hasPaidAccess && VpnEngine.instance.isConnected
                          ? 'တန်းချိန်း'
                          : 'ပြောင်းမယ်',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.keyboard_arrow_down, size: 16, color: accent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Remaining GB + Expiry Date card (Feature 14).
  /// Shows Marzban subscription GB/expiry if available, and/or VIP code expiry.
  Widget _buildPlanInfoCard(AppStore store) {
    final info = store.activeSubscriptionUserInfo;
    final vipExpiry = store.hasNoAdsAccess ? store.noAdsExpiresAt : null;
    if (info == null && vipExpiry == null) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final accent = Theme.of(context).colorScheme.primary;

    final remainingBytes = info?.remaining;
    final totalBytes = info?.total ?? 0;
    final usedFraction = (totalBytes > 0 && remainingBytes != null)
        ? ((totalBytes - remainingBytes) / totalBytes).clamp(0.0, 1.0)
        : null;
    final expireAt = info?.expireAt ?? vipExpiry;
    final daysLeft = expireAt != null
        ? expireAt.difference(DateTime.now()).inDays
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    vipExpiry != null ? Icons.workspace_premium : Icons.cloud_done,
                    color: vipExpiry != null ? Colors.amber : accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    vipExpiry != null ? 'VIP / Subscription အချက်အလက်' : 'Subscription လက်ကျန်',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (remainingBytes != null)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ကျန်ရှိ GB',
                              style: TextStyle(color: muted, fontSize: 11)),
                          const SizedBox(height: 2),
                          Text(
                            '${(remainingBytes < 0 ? 0.0 : remainingBytes / 1e9).toStringAsFixed(2)} GB',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (expireAt != null)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('သက်တမ်းကုန်ရက်',
                              style: TextStyle(color: muted, fontSize: 11)),
                          const SizedBox(height: 2),
                          Text(
                            '${expireAt.year}-${expireAt.month.toString().padLeft(2, '0')}-${expireAt.day.toString().padLeft(2, '0')}'
                            '${daysLeft != null && daysLeft >= 0 ? ' ($daysLeft ရက်)' : ''}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              if (usedFraction != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (1.0 - usedFraction).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: accent.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Total Data Usage + Reset + Speedtest button row (Features 3 & 8).
  Widget _buildTotalUsageAndToolsRow(AppStore store) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final totalBytes = store.totalDataBytes + _sessionBufferedDelta;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.data_usage,
                size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('စုစုပေါင်း သုံးစွဲမှု',
                      style: TextStyle(color: muted, fontSize: 11)),
                  Text(
                    _fmtBytes(totalBytes),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _confirmResetDataUsage,
              child: const Text('Reset'),
            ),
            const SizedBox(width: 4),
            OutlinedButton.icon(
              onPressed: _openSpeedtestDialog,
              icon: const Icon(Icons.speed, size: 16),
              label: const Text('Speedtest'),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeLeftCard() {
    final credit = _timeCredit;
    if (credit == null) return const SizedBox.shrink();
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.timer, color: Theme.of(context).colorScheme.secondary),
            const SizedBox(width: 10),
            StreamBuilder<int>(
              stream: credit.remainingStream,
              initialData: credit.remainingSeconds,
              builder: (context, snapshot) {
                final remaining = snapshot.data ?? credit.remainingSeconds;
                return Text(
                  'Time Left: ${TimeCreditService.format(remaining)}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                );
              },
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: _showAddTimeDialog,
              child: const Text('Add Time'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBannerSlot(AppStore store) {
    final isBuyer = store.hasPaidAccess;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
      color: isDark ? Colors.black.withValues(alpha: 0.25) : Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isBuyer) ...[
            const Center(child: AdBanner()),
            const SizedBox(height: 8),
          ],
          const Center(child: OwnAdBanner()),
        ],
      ),
    );
  }

  Widget _speedRow() {
    return StreamBuilder<VpnStats>(
      stream: VpnEngine.instance.statsStream,
      initialData: const VpnStats(),
      builder: (context, snapshot) {
        final speed = snapshot.data ?? const VpnStats();
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.arrow_upward, size: 16, color: Colors.green),
            Text(' ${_fmtSpeed(speed.upSpeed)}  '),
            const Icon(Icons.arrow_downward, size: 16, color: Colors.cyan),
            Text(' ${_fmtSpeed(speed.downSpeed)}'),
          ],
        );
      },
    );
  }

  String _fmtSpeed(int bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '$bytesPerSec B/s';
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  Widget _signalBars(int ping, bool isDark) {
    final bars = ping <= 100
        ? 3
        : ping <= 200
            ? 2
            : ping <= 350
                ? 1
                : 0;
    final offColor = isDark ? Colors.white24 : Colors.black12;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        final on = i < bars;
        return Container(
          width: 3,
          height: 4.0 + i * 3,
          margin: const EdgeInsets.only(left: 1.5),
          decoration: BoxDecoration(
            color: on ? Colors.green : offColor,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

/// Modal Bottom Sheet for server selection right on the VPN tab (v1.0.10):
/// - Search by server name / country / protocol
/// - Auto-fastest pick + Update buttons
/// - Frequently used servers pinned on top
/// - Premium / My Servers / Free Servers (country-grouped)
/// - VIP instant server switch support
class _ServerPickerSheet extends StatefulWidget {
  final AppStore store;
  final Map<String, int?> pings;
  final bool refreshing;
  final String Function(VpnServer) serverDisplayName;
  final Future<void> Function(VpnServer) onSelectServer;
  final Future<void> Function(VpnServer) onToggleFavourite;
  final Future<void> Function() onPickFastest;
  final Future<void> Function() onRefresh;
  final VoidCallback onBuyPremium;

  const _ServerPickerSheet({
    required this.store,
    required this.pings,
    required this.refreshing,
    required this.serverDisplayName,
    required this.onSelectServer,
    required this.onToggleFavourite,
    required this.onPickFastest,
    required this.onRefresh,
    required this.onBuyPremium,
  });

  @override
  State<_ServerPickerSheet> createState() => _ServerPickerSheetState();
}

class _ServerPickerSheetState extends State<_ServerPickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  final Set<String> _expandedGroups = {};
  bool _localRefreshing = false;

  @override
  void initState() {
    super.initState();
    _localRefreshing = widget.refreshing;
    final sel = widget.store.selectedServer;
    if (sel != null) {
      _expandedGroups.add('${sel.subscriptionId}|${sel.countryCode}');
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matchesQuery(VpnServer s) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final disp = widget.serverDisplayName(s).toLowerCase();
    return disp.contains(q) ||
        s.name.toLowerCase().contains(q) ||
        s.countryName.toLowerCase().contains(q) ||
        s.countryCode.toLowerCase().contains(q) ||
        s.protocol.label.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final frequent = store
        .frequentServers(limit: 4)
        .where(_matchesQuery)
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: muted.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'ဆာဗာ ရွေးချယ်ရန်',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (store.hasPaidAccess && VpnEngine.instance.isConnected)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'VIP တန်းချိန်းရတယ်',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.amber,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            // Search bar (Feature 5)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'ဆာဗာ နာမည် / နိုင်ငံ ရှာရန်…',
                  isDense: true,
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
              ),
            ),
            // Fastest + Update buttons (Feature 4)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _localRefreshing ? null : widget.onPickFastest,
                      icon: const Icon(Icons.bolt, size: 18),
                      label: const Text('အမြန်ဆုံး ရွေးမယ်'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _localRefreshing
                          ? null
                          : () async {
                              setState(() => _localRefreshing = true);
                              await widget.onRefresh();
                              if (mounted) {
                                setState(() => _localRefreshing = false);
                              }
                            },
                      icon: _localRefreshing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(_localRefreshing ? 'ဆွဲနေတယ်…' : 'Update'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // Frequent servers on top (Feature 6)
                  if (frequent.isNotEmpty) ...[
                    _sectionHeader('🔥 မကြာခဏ သုံးတဲ့ ဆာဗာများ'),
                    Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        children: frequent
                            .map((s) => _serverRow(s, showCountryFlag: true))
                            .toList(),
                      ),
                    ),
                  ],
                  _buildPremiumSection(store, muted),
                  const SizedBox(height: 8),
                  _buildMyServersSection(store, muted),
                  const SizedBox(height: 8),
                  _buildFreeSection(store, muted),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildPremiumSection(AppStore store, Color muted) {
    final buyerServers = (store.serversCache[AppStore.buyerSubId] ?? [])
        .where(_matchesQuery)
        .toList();
    if (store.hasNoAdsAccess) {
      if (buyerServers.isEmpty) {
        if (_query.isNotEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('⭐ Premium Servers'),
            Text(
              'Premium server မရှိသေးပါ — @amktvpn ကို ဆက်သွယ်ပါ',
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('⭐ Premium Servers'),
          _sectionGroups(store, AppStore.buyerSubId, buyerServers),
        ],
      );
    }
    if (_query.isNotEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('⭐ Premium Servers'),
        Card(
          elevation: 0,
          child: ListTile(
            leading: const Icon(Icons.lock, color: Colors.amber),
            title: const Text('Premium Server'),
            subtitle: Text(
              'သီးသန့်ဆာဗာ — ၃,၅၀၀ Ks/month',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Locked',
                style: TextStyle(
                    color: Colors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
            onTap: widget.onBuyPremium,
          ),
        ),
      ],
    );
  }

  Widget _buildMyServersSection(AppStore store, Color muted) {
    final userSubs = store.subscriptions
        .where((s) => s.id != AppStore.freeSubId)
        .toList();
    final manual = (store.serversCache[AppStore.manualSubId] ?? [])
        .where(_matchesQuery)
        .toList();
    final children = <Widget>[];
    for (final sub in userSubs) {
      final servers = (store.serversCache[sub.id] ?? [])
          .where(_matchesQuery)
          .toList();
      if (servers.isEmpty) continue;
      children.add(_sectionHeader('🔗 ${sub.label}'));
      if (store.isOwnSubscription(sub.id)) {
        children.add(Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'ကိုယ့် subscription — ကြော်ငြာ မပေါ်ဘူး',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ));
      }
      children.add(_sectionGroups(store, sub.id, servers));
      children.add(const SizedBox(height: 8));
    }
    if (manual.isNotEmpty) {
      children.add(_sectionHeader('✏️ ကိုယ်တိုင် ဆာဗာ'));
      children.add(_sectionGroups(store, AppStore.manualSubId, manual));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildFreeSection(AppStore store, Color muted) {
    final servers = (store.serversCache[AppStore.freeSubId] ?? [])
        .where(_matchesQuery)
        .toList();
    if (servers.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('🌐 Free Servers'),
          Card(
            elevation: 0,
            child: ListTile(
              title: Text(
                _query.isNotEmpty
                    ? '"$_query" နဲ့ ကိုက်ညီတဲ့ ဆာဗာ မတွေ့ပါ'
                    : 'Server မရှိသေးပါ',
              ),
              subtitle: _query.isEmpty
                  ? Text('Update နှိပ်ပြီး server ဆွဲပါ',
                      style: TextStyle(color: muted, fontSize: 12))
                  : null,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('🌐 Free Servers'),
        _sectionGroups(store, AppStore.freeSubId, servers),
      ],
    );
  }

  Widget _sectionGroups(
      AppStore store, String subscriptionId, List<VpnServer> servers) {
    final Map<String, List<VpnServer>> byCountry = {};
    final List<String> countryOrder = [];
    for (final s in servers) {
      final code = s.countryCode;
      if (!byCountry.containsKey(code)) {
        byCountry[code] = [];
        countryOrder.add(code);
      }
      byCountry[code]!.add(s);
    }
    final favIds = store.favouriteServerIds;
    final useCounts = store.serverUseCounts;
    final favCodes = <String>{};
    for (final s in servers) {
      if (favIds.contains(s.id)) favCodes.add(s.countryCode);
    }
    // Sort country groups: favourites first, then highest usage count, then original order.
    final orderedCodes = List<String>.of(countryOrder);
    orderedCodes.sort((a, b) {
      final fa = favCodes.contains(a) ? 1 : 0;
      final fb = favCodes.contains(b) ? 1 : 0;
      if (fa != fb) return fb.compareTo(fa);
      final ua = byCountry[a]!
          .fold<int>(0, (sum, s) => sum + (useCounts[s.id] ?? 0));
      final ub = byCountry[b]!
          .fold<int>(0, (sum, s) => sum + (useCounts[s.id] ?? 0));
      if (ua != ub) return ub.compareTo(ua);
      return countryOrder.indexOf(a).compareTo(countryOrder.indexOf(b));
    });
    return Column(
      children: orderedCodes
          .map((code) => _countryGroupCard(store, subscriptionId, code,
              byCountry[code]!, favCodes.contains(code)))
          .toList(),
    );
  }

  Widget _countryGroupCard(AppStore store, String subscriptionId,
      String countryCode, List<VpnServer> group, bool hasFavourite) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final key = '$subscriptionId|$countryCode';
    // Auto-expand while searching so matching servers are immediately visible.
    final expanded = _query.isNotEmpty || _expandedGroups.contains(key);
    final first = group.first;
    final connectedId = VpnEngine.instance.currentServer?.id;
    final groupHasConnected = group.any((s) => s.id == connectedId);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            leading:
                Text(first.countryFlag, style: const TextStyle(fontSize: 22)),
            title: Text(
              first.countryName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${group.length} server${group.length == 1 ? '' : 's'}'
              '${groupHasConnected ? ' • ချိတ်ထားတယ်' : ''}',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasFavourite)
                  const Icon(Icons.star, color: Colors.amber, size: 18),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
            onTap: () {
              setState(() {
                if (_expandedGroups.contains(key)) {
                  _expandedGroups.remove(key);
                } else {
                  _expandedGroups.add(key);
                }
              });
            },
          ),
          if (expanded) ...group.map((s) => _serverRow(s)),
        ],
      ),
    );
  }

  Widget _serverRow(VpnServer server, {bool showCountryFlag = false}) {
    final store = widget.store;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final accent = Theme.of(context).colorScheme.primary;
    final selected = store.selectedServerId == server.id;
    final connected = VpnEngine.instance.currentServer?.id == server.id;
    final isFavourite = store.favouriteServerIds.contains(server.id);
    final ping = widget.pings[server.id];
    final bars = ping == null
        ? 0
        : ping <= 100
            ? 3
            : ping <= 200
                ? 2
                : ping <= 350
                    ? 1
                    : 0;
    final offColor = isDark ? Colors.white24 : Colors.black12;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
      leading: showCountryFlag
          ? Text(server.countryFlag, style: const TextStyle(fontSize: 20))
          : Icon(
              _protocolIcon(server.protocol),
              color: selected ? accent : muted,
              size: 20,
            ),
      title: Text(
        widget.serverDisplayName(server),
        style: TextStyle(
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: server.canConnect ? null : muted,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${showCountryFlag ? '${server.countryName} • ' : ''}'
        '${server.protocol.label}'
        '${server.canConnect ? '' : ' — မကြာမီ'}'
        '${ping != null ? ' • $ping ms' : ''}',
        style: TextStyle(color: muted, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (ping != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(3, (i) {
                final on = i < bars;
                return Container(
                  width: 3,
                  height: 4.0 + i * 3,
                  margin: const EdgeInsets.only(left: 1.5),
                  decoration: BoxDecoration(
                    color: on ? Colors.green : offColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                );
              }),
            ),
          if (connected)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.check_circle, color: Colors.green, size: 18),
            ),
          IconButton(
            icon: Icon(
              isFavourite ? Icons.star : Icons.star_border,
              color: isFavourite ? Colors.amber : muted,
              size: 20,
            ),
            onPressed: () async {
              await widget.onToggleFavourite(server);
              if (mounted) setState(() {});
            },
            tooltip: isFavourite ? 'Favourite ဖြုတ်မယ်' : 'Favourite ထားမယ်',
          ),
        ],
      ),
      selected: selected,
      selectedTileColor: accent.withValues(alpha: 0.12),
      onTap: () => widget.onSelectServer(server),
    );
  }

  IconData _protocolIcon(VpnProtocol p) {
    switch (p) {
      case VpnProtocol.vless:
        return Icons.flash_on;
      case VpnProtocol.vmess:
        return Icons.bolt;
      case VpnProtocol.trojan:
        return Icons.shield;
      case VpnProtocol.shadowsocks:
        return Icons.visibility_off;
      case VpnProtocol.openvpn:
        return Icons.vpn_key;
      case VpnProtocol.dnstt:
      case VpnProtocol.slowdns:
        return Icons.dns;
    }
  }
}

/// On-demand Speedtest dialog (Feature 8 — only runs when user taps Speedtest).
class _SpeedtestDialog extends StatefulWidget {
  const _SpeedtestDialog();

  @override
  State<_SpeedtestDialog> createState() => _SpeedtestDialogState();
}

class _SpeedtestDialogState extends State<_SpeedtestDialog> {
  SpeedtestProgress _state =
      const SpeedtestProgress(stage: 'idle', progress: 0);
  bool _running = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _startTest();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _startTest() async {
    if (_running) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _state = const SpeedtestProgress(stage: 'ping', progress: 0.05);
    });
    final result = await NetworkToolsService.runSpeedtest(
      onProgress: (p) {
        if (mounted && !_cancelled) {
          setState(() => _state = p);
        }
      },
      isCancelled: () => _cancelled,
    );
    if (mounted) {
      setState(() {
        _state = result;
        _running = false;
      });
    }
  }

  String _stageLabel(String stage) => switch (stage) {
        'ping' => 'Ping စစ်နေတယ်…',
        'download' => 'Download မြန်နှုန်း စစ်နေတယ်…',
        'upload' => 'Upload မြန်နှုန်း စစ်နေတယ်…',
        'done' => 'စစ်ဆေးပြီးပါပြီ',
        'error' => _state.error ?? 'စစ်မရပါ',
        _ => 'အသင့်ဖြစ်ပြီ',
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final accent = Theme.of(context).colorScheme.primary;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(Icons.speed, color: accent),
          const SizedBox(width: 8),
          const Text('Speedtest'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _stageLabel(_state.stage),
            style: TextStyle(
              color: _state.stage == 'error' ? Colors.orange : muted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _running ? _state.progress.clamp(0.05, 1.0) : (_state.stage == 'done' ? 1.0 : 0.0),
              minHeight: 7,
              backgroundColor: accent.withValues(alpha: 0.16),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _metricTile(
                'Ping',
                _state.pingMs != null ? '${_state.pingMs} ms' : '—',
                muted,
              ),
              _metricTile(
                'Download',
                _state.downloadMbps != null
                    ? '${_state.downloadMbps!.toStringAsFixed(1)} Mbps'
                    : '—',
                muted,
              ),
              _metricTile(
                'Upload',
                _state.uploadMbps != null
                    ? '${_state.uploadMbps!.toStringAsFixed(1)} Mbps'
                    : '—',
                muted,
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (!_running)
          TextButton(
            onPressed: _startTest,
            child: const Text('ပြန်စစ်မယ်'),
          ),
        ElevatedButton(
          onPressed: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
          child: Text(_running ? 'ပယ်ဖျက်မယ်' : 'ပိတ်မယ်'),
        ),
      ],
    );
  }

  Widget _metricTile(String label, String value, Color muted) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(color: muted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Add Time dialog: extend BEFORE connecting.
class _AddTimeDialog extends StatefulWidget {
  final TimeCreditService credit;

  const _AddTimeDialog({required this.credit});

  @override
  State<_AddTimeDialog> createState() => _AddTimeDialogState();
}

class _AddTimeDialogState extends State<_AddTimeDialog> {
  static const _watchSeconds = 5;
  int _remaining = _watchSeconds;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _watchAndGet() async {
    if (_busy || !widget.credit.canExtend) return;
    setState(() => _busy = true);
    final ok = await widget.credit.extend();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final credit = widget.credit;
    final canExtend = credit.canExtend;
    final watchDone = _remaining <= 0;
    return AlertDialog(
      title: const Text('Add Time'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Please extend your time before connecting the VPN. Watch for about 5 seconds to get 9 hours.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.open_in_browser,
                  size: 16, color: Theme.of(context).colorScheme.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'ကြော်ငြာ browser မှာ ပွင့်သွားပြီ — ၅ စက္ကန့် စောင့်ပါ',
                  style: TextStyle(color: muted, fontSize: 13),
                  softWrap: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Extends left today: ${credit.extendsLeftToday}',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            'Time Left: ${TimeCreditService.format(credit.remainingSeconds)}',
            style: TextStyle(color: muted, fontSize: 13),
          ),
          if (!canExtend)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'ဒီနေ့ အချိန်တိုးတာ ၂ ခါ ပြည့်သွားပြီ — မနက်ဖြန် ထပ်တိုးလို့ရပါတယ်။ ကုတ် ဝယ်ထားရင် အချိန် ကန့်သတ်ချက် မရှိပါ။',
                style: TextStyle(color: Colors.orange, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: (canExtend && watchDone && !_busy) ? _watchAndGet : null,
          child: Text(
            _busy
                ? 'ထည့်နေတယ်…'
                : watchDone
                    ? 'Watch & Get 9 Hours'
                    : 'Watch & Get 9 Hours ($_remaining)',
          ),
        ),
      ],
    );
  }
}

/// Session traffic panel: live up/down wave + current session usage.
class _TrafficPanel extends StatefulWidget {
  const _TrafficPanel();

  @override
  State<_TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<_TrafficPanel> {
  static const _maxSamples = 40;
  final List<double> _up = [];
  final List<double> _down = [];
  VpnStats _latest = const VpnStats();
  StreamSubscription<VpnStats>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = VpnEngine.instance.statsStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _latest = s;
        _up.add(s.upSpeed.toDouble());
        _down.add(s.downSpeed.toDouble());
        if (_up.length > _maxSamples) _up.removeAt(0);
        if (_down.length > _maxSamples) _down.removeAt(0);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    return Column(
      children: [
        const SizedBox(height: 10),
        SizedBox(
          height: 52,
          width: double.infinity,
          child: CustomPaint(
            painter: _SpeedWavePainter(
              up: _up,
              down: _down,
              maxSamples: _maxSamples,
              baselineColor: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.12),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('ဒီတစ်ခါ: ', style: TextStyle(color: muted, fontSize: 12)),
            const Icon(Icons.arrow_upward, size: 14, color: Colors.green),
            Text(' ${_fmtBytes(_latest.upTotal)}',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 12),
            const Icon(Icons.arrow_downward, size: 14, color: Colors.cyan),
            Text(' ${_fmtBytes(_latest.downTotal)}',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      ],
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

class _SpeedWavePainter extends CustomPainter {
  final List<double> up;
  final List<double> down;
  final int maxSamples;
  final Color baselineColor;

  const _SpeedWavePainter({
    required this.up,
    required this.down,
    required this.maxSamples,
    required this.baselineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    double maxV = 1024;
    for (final v in up) {
      if (v > maxV) maxV = v;
    }
    for (final v in down) {
      if (v > maxV) maxV = v;
    }
    final basePaint = Paint()
      ..color = baselineColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1),
        Offset(size.width, size.height - 1), basePaint);
    _drawLine(canvas, size, down, maxV, const Color(0xFF0EA5E9));
    _drawLine(canvas, size, up, maxV, const Color(0xFF10B981));
  }

  void _drawLine(Canvas canvas, Size size, List<double> values, double maxV,
      Color color) {
    if (values.length < 2) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    final step = size.width / (maxSamples - 1);
    final startX = size.width - (values.length - 1) * step;
    for (var i = 0; i < values.length; i++) {
      final x = startX + i * step;
      final norm = (values[i] / maxV).clamp(0.0, 1.0);
      final y = size.height - 2 - norm * (size.height - 6);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SpeedWavePainter oldDelegate) => true;
}
