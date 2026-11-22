import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/vpn_server.dart';
import 'subscription_service.dart';

/// One subscription source. The free one is baked into the app
/// (AmktConfig.defaultFreeSubscriptionUrl) and never shown in the UI;
/// the user adds their own paid Marzban subscription links here.
class SubscriptionEntry {
  final String id;
  final String url; // '' for the manual bucket
  final String label;
  final bool isPaid; // paid = no ads, no delay
  final DateTime addedAt;

  const SubscriptionEntry({
    required this.id,
    required this.url,
    required this.label,
    required this.isPaid,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'label': label,
        'isPaid': isPaid,
        'addedAt': addedAt.toIso8601String(),
      };

  factory SubscriptionEntry.fromJson(Map<String, dynamic> j) =>
      SubscriptionEntry(
        id: j['id'] as String,
        url: j['url'] as String? ?? '',
        label: j['label'] as String? ?? '',
        isPaid: j['isPaid'] as bool? ?? false,
        addedAt: DateTime.tryParse(j['addedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// One completed VPN connection session (v1.0.10 Connection History).
class ConnectionHistoryEntry {
  final String serverName;
  final String countryCode;
  final String countryFlag;
  final String countryName;
  final String protocol;
  final DateTime connectedAt;
  final DateTime disconnectedAt;
  final int durationSeconds;
  final int dataBytes;

  const ConnectionHistoryEntry({
    required this.serverName,
    required this.countryCode,
    required this.countryFlag,
    required this.countryName,
    required this.protocol,
    required this.connectedAt,
    required this.disconnectedAt,
    required this.durationSeconds,
    required this.dataBytes,
  });

  Map<String, dynamic> toJson() => {
        'serverName': serverName,
        'countryCode': countryCode,
        'countryFlag': countryFlag,
        'countryName': countryName,
        'protocol': protocol,
        'connectedAt': connectedAt.toIso8601String(),
        'disconnectedAt': disconnectedAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'dataBytes': dataBytes,
      };

  factory ConnectionHistoryEntry.fromJson(Map<String, dynamic> j) =>
      ConnectionHistoryEntry(
        serverName: j['serverName'] as String? ?? 'Server',
        countryCode: j['countryCode'] as String? ?? '',
        countryFlag: j['countryFlag'] as String? ?? '🌐',
        countryName: j['countryName'] as String? ?? 'အခြား',
        protocol: j['protocol'] as String? ?? '',
        connectedAt: DateTime.tryParse(j['connectedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        disconnectedAt:
            DateTime.tryParse(j['disconnectedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        durationSeconds: (j['durationSeconds'] as num?)?.toInt() ?? 0,
        dataBytes: (j['dataBytes'] as num?)?.toInt() ?? 0,
      );
}

/// Local storage: subscriptions, cached server lists, selection, usage,
/// frequent servers, and connection history.
class AppStore {
  static const _kSubs = 'subscriptions';
  static const _kServers = 'servers_cache';
  static const _kSelected = 'selected_server_id';
  static const _kFavs = 'favourite_server_ids';
  static const _kUserInfo = 'subscription_userinfo';
  static const _kKillSwitch = 'kill_switch';
  static const _kNoAdsCode = 'noads_code';
  static const _kNoAdsExpires = 'noads_expires_at';
  static const _kNoAdsDeviceId = 'noads_device_id';
  static const _kNotifAsked = 'notif_permission_asked';
  static const _kThemeMode = 'theme_mode';
  static const _kTotalDataBytes = 'total_data_bytes';
  static const _kServerUseCounts = 'server_use_counts';
  static const _kConnectionHistory = 'connection_history';

  static const String freeSubId = 'free';
  static const String manualSubId = 'manual';
  static const String _kPerAppPkgs = 'per_app_packages';

  /// Buyer-only servers (code-gated, fetched from the n8n webhook —
  /// never from the public free list). Not a real subscription entry:
  /// it is only a cache bucket, shown only while a no-ads code is valid.
  static const String buyerSubId = 'buyer';

  final SharedPreferences _prefs;
  AppStore(this._prefs);

  static Future<AppStore> load() async =>
      AppStore(await SharedPreferences.getInstance());

  /// The free list URL — always the baked-in default, never user-editable,
  /// so the free subscription cannot be seen or changed from the UI.
  String get freeSubscriptionUrl => AmktConfig.defaultFreeSubscriptionUrl;

  List<SubscriptionEntry> get subscriptions {
    final raw = _prefs.getString(_kSubs);
    if (raw == null) {
      return [
        SubscriptionEntry(
          id: freeSubId,
          url: freeSubscriptionUrl,
          label: 'AMKT Free',
          isPaid: false,
          addedAt: DateTime.now(),
        ),
      ];
    }
    try {
      final list = jsonDecode(raw) as List;
      final entries = list
          .map((e) => SubscriptionEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!entries.any((e) => e.id == freeSubId)) {
        entries.insert(
            0,
            SubscriptionEntry(
              id: freeSubId,
              url: freeSubscriptionUrl,
              label: 'AMKT Free',
              isPaid: false,
              addedAt: DateTime.now(),
            ));
      }
      return entries;
    } catch (_) {
      return [];
    }
  }

  Map<String, List<VpnServer>> get serversCache {
    final raw = _prefs.getString(_kServers);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, List<VpnServer>>{};
      for (final e in map.entries) {
        final servers = <VpnServer>[];
        if (e.value is List) {
          for (final item in (e.value as List)) {
            try {
              servers.add(VpnServer.fromJson(item as Map<String, dynamic>));
            } catch (_) {
              // skip stale server
            }
          }
        }
        out[e.key] = servers;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveServersCache(Map<String, List<VpnServer>> cache) async =>
      _prefs.setString(
          _kServers,
          jsonEncode(cache.map((k, v) =>
              MapEntry(k, v.map((s) => s.toJson()).toList()))));

  Future<void> saveServers(String subId, List<VpnServer> servers) async {
    final cache = serversCache;
    cache[subId] = servers;
    await _saveServersCache(cache);
  }

  List<VpnServer> get allServers {
    final subIds = {
      freeSubId,
      buyerSubId,
      manualSubId,
      ...subscriptions.map((s) => s.id),
    };
    return serversCache.entries
        .where((e) => subIds.contains(e.key))
        .expand((e) => e.value)
        .toList();
  }

  // ------------------------------------------- subscriptions (v1.0.8 restore)

  Future<String> addSubscription(String url,
      {required bool isPaid, String? id}) async {
    id ??=
        'sub-${DateTime.now().millisecondsSinceEpoch}-${url.hashCode.abs()}';
    final uri = Uri.tryParse(url.trim());
    final label = (uri != null && uri.host.isNotEmpty)
        ? uri.host
        : 'Subscription ${subscriptions.length}';
    final entries = subscriptions;
    entries.add(SubscriptionEntry(
      id: id,
      url: url.trim(),
      label: label,
      isPaid: isPaid,
      addedAt: DateTime.now(),
    ));
    await _saveSubscriptions(entries);
    return id;
  }

  Future<void> removeSubscription(String id) async {
    final entries = subscriptions..removeWhere((e) => e.id == id);
    await _saveSubscriptions(entries);
    final cache = serversCache;
    cache.remove(id);
    await _saveServersCache(cache);
    await saveUserInfo(id, null);
    if (selectedServer?.subscriptionId == id) {
      await setSelectedServerId(null);
    }
  }

  Future<void> _saveSubscriptions(List<SubscriptionEntry> entries) async {
    await _prefs.setString(
        _kSubs, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  bool get hasOwnSubscription => subscriptions.any((e) =>
      e.id != freeSubId && isOwnSubscriptionUrl(e.url));

  bool isOwnSubscription(String subId) {
    for (final e in subscriptions) {
      if (e.id == subId) return isOwnSubscriptionUrl(e.url);
    }
    return false;
  }

  static bool isOwnSubscriptionUrl(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    return AmktConfig.ownSubscriptionHosts.contains(host);
  }

  /// Paid/VIP treatment gate: valid no-ads code OR own-panel subscription.
  bool get hasPaidAccess => hasNoAdsAccess || hasOwnSubscription;

  /// True when connecting with [server] gets paid/VIP treatment.
  bool hidesAdsFor(VpnServer? server) {
    if (hasNoAdsAccess) return true;
    if (server == null) return false;
    return isOwnSubscription(server.subscriptionId);
  }

  // ------------------------------------------------- manual keys

  Future<void> addManualServer(VpnServer server) async {
    final cache = serversCache;
    final list = cache[manualSubId] ?? [];
    list.removeWhere((s) => s.id == server.id);
    list.add(server);
    cache[manualSubId] = list;
    await _saveServersCache(cache);
  }

  Future<void> removeManualServer(String id) async {
    final cache = serversCache;
    final list = cache[manualSubId] ?? [];
    list.removeWhere((s) => s.id == id);
    cache[manualSubId] = list;
    await _saveServersCache(cache);
    if (selectedServerId == id) await setSelectedServerId(null);
  }

  // ------------------------------------------------------- theme

  String get themeMode => _prefs.getString(_kThemeMode) ?? 'light';

  Future<void> setThemeMode(String mode) async {
    await _prefs.setString(_kThemeMode, mode);
  }

  // ------------------------------------------------------- usage info (Marzban)

  SubscriptionUserInfo? getUserInfo(String subId) {
    final raw = _prefs.getString(_kUserInfo);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final j = map[subId];
      if (j is! Map<String, dynamic>) return null;
      return SubscriptionUserInfo.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveUserInfo(String subId, SubscriptionUserInfo? info) async {
    final raw = _prefs.getString(_kUserInfo);
    Map<String, dynamic> map = {};
    if (raw != null) {
      try {
        map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        map = {};
      }
    }
    if (info == null) {
      map.remove(subId);
    } else {
      map[subId] = info.toJson();
    }
    await _prefs.setString(_kUserInfo, jsonEncode(map));
  }

  /// First available subscription userinfo (preferring the selected server's
  /// subscription, then any user subscription with GB/expiry info).
  SubscriptionUserInfo? get activeSubscriptionUserInfo {
    final sel = selectedServer;
    if (sel != null) {
      final info = getUserInfo(sel.subscriptionId);
      if (info != null && info.hasAny) return info;
    }
    for (final sub in subscriptions) {
      if (sub.id == freeSubId) continue;
      final info = getUserInfo(sub.id);
      if (info != null && info.hasAny) return info;
    }
    return null;
  }

  // ------------------------------------------- total data usage (v1.0.10)

  /// Cumulative data used across VPN sessions (combined up + down bytes).
  int get totalDataBytes => _prefs.getInt(_kTotalDataBytes) ?? 0;

  Future<void> addTotalDataBytes(int deltaBytes) async {
    if (deltaBytes <= 0) return;
    await _prefs.setInt(_kTotalDataBytes, totalDataBytes + deltaBytes);
  }

  Future<void> resetTotalDataBytes() async {
    await _prefs.setInt(_kTotalDataBytes, 0);
  }

  // ------------------------------------------- frequent servers (v1.0.10)

  Map<String, int> get serverUseCounts {
    final raw = _prefs.getString(_kServerUseCounts);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num?)?.toInt() ?? 0));
    } catch (_) {
      return {};
    }
  }

  Future<void> recordServerUse(String serverId) async {
    final counts = serverUseCounts;
    counts[serverId] = (counts[serverId] ?? 0) + 1;
    await _prefs.setString(_kServerUseCounts, jsonEncode(counts));
  }

  /// Top most-frequently used servers that still exist in the current list.
  List<VpnServer> frequentServers({int limit = 5}) {
    final counts = serverUseCounts;
    if (counts.isEmpty) return const [];
    final available = allServers.where((s) => (counts[s.id] ?? 0) > 0).toList();
    available.sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
    if (available.length > limit) {
      return available.sublist(0, limit);
    }
    return available;
  }

  // ------------------------------------------- connection history (v1.0.10)

  List<ConnectionHistoryEntry> get connectionHistory {
    final raw = _prefs.getString(_kConnectionHistory);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) =>
              ConnectionHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> addConnectionHistory(ConnectionHistoryEntry entry) async {
    final list = List<ConnectionHistoryEntry>.of(connectionHistory);
    list.insert(0, entry);
    if (list.length > 50) {
      list.removeRange(50, list.length);
    }
    await _prefs.setString(
      _kConnectionHistory,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> clearConnectionHistory() async {
    await _prefs.remove(_kConnectionHistory);
  }

  // ---------------------------------------------------------- kill switch

  bool get killSwitch => _prefs.getBool(_kKillSwitch) ?? false;

  Future<void> setKillSwitch(bool value) async {
    await _prefs.setBool(_kKillSwitch, value);
  }

  // ------------------------------------------- notification permission ask

  bool get notifPermissionAsked => _prefs.getBool(_kNotifAsked) ?? false;

  Future<void> markNotifPermissionAsked() async {
    await _prefs.setBool(_kNotifAsked, true);
  }

  // ----------------------------------------------------- no-ads code

  String? get noAdsCode => _prefs.getString(_kNoAdsCode);

  DateTime? get noAdsExpiresAt {
    final raw = _prefs.getString(_kNoAdsExpires);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  bool get hasNoAdsAccess {
    final code = noAdsCode;
    final exp = noAdsExpiresAt;
    return code != null &&
        code.isNotEmpty &&
        exp != null &&
        exp.isAfter(DateTime.now());
  }

  Future<void> saveNoAdsCode(String code, DateTime? expiresAt) async {
    await _prefs.setString(_kNoAdsCode, code.trim().toUpperCase());
    if (expiresAt == null) {
      await _prefs.remove(_kNoAdsExpires);
    } else {
      await _prefs.setString(_kNoAdsExpires, expiresAt.toIso8601String());
    }
  }

  Future<void> clearNoAdsCode() async {
    await _prefs.remove(_kNoAdsCode);
    await _prefs.remove(_kNoAdsExpires);
    final cache = serversCache;
    cache.remove(buyerSubId);
    await _saveServersCache(cache);
  }

  Future<String> getOrCreateDeviceId() async {
    final existing = _prefs.getString(_kNoAdsDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final id = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _prefs.setString(_kNoAdsDeviceId, id);
    return id;
  }

  // --------------------------------------------------- per-app VPN

  Set<String> get perAppPackages {
    final raw = _prefs.getStringList(_kPerAppPkgs);
    return raw == null ? <String>{} : raw.toSet();
  }

  Future<void> setPerAppPackages(Set<String> pkgs) async {
    await _prefs.setStringList(_kPerAppPkgs, pkgs.toList());
  }

  String? get selectedServerId => _prefs.getString(_kSelected);

  Set<String> get favouriteServerIds {
    final raw = _prefs.getStringList(_kFavs);
    return raw == null ? <String>{} : raw.toSet();
  }

  Future<void> toggleFavourite(String id) async {
    final favs = favouriteServerIds;
    if (favs.contains(id)) {
      favs.remove(id);
    } else {
      favs.add(id);
    }
    await _prefs.setStringList(_kFavs, favs.toList());
  }

  Future<void> setSelectedServerId(String? id) async {
    if (id == null) {
      await _prefs.remove(_kSelected);
    } else {
      await _prefs.setString(_kSelected, id);
    }
  }

  VpnServer? get selectedServer {
    final id = selectedServerId;
    if (id == null) return null;
    for (final s in allServers) {
      if (s.id == id) return s;
    }
    return null;
  }
}
