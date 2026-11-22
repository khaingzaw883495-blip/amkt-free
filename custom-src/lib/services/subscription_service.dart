import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/vpn_server.dart';

/// Usage info a Marzban subscription reports in the
/// `subscription-userinfo` response header:
/// `upload=...; download=...; total=...; expire=...`
/// All values are bytes, except `expire` which is a Unix timestamp
/// (seconds, 0 = never expires). Any field may be missing — a missing
/// field means "unknown", never a made-up value.
class SubscriptionUserInfo {
  final int upload;
  final int download;
  final int total;
  final int expire;

  const SubscriptionUserInfo({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
  });

  /// Bytes used so far (upload + download).
  int get used => upload + download;

  /// Bytes left, or null when the plan has no total (unlimited).
  int? get remaining => total > 0 ? total - used : null;

  /// Expiry as a DateTime, or null when unknown / never.
  DateTime? get expireAt =>
      expire > 0 ? DateTime.fromMillisecondsSinceEpoch(expire * 1000) : null;

  /// True when the header carried at least one usable value.
  bool get hasAny => total > 0 || expire > 0;

  /// One-line Burmese summary ("ကျန်: 12.5 GB • ကုန်ဆုံးရက်: 2026-12-20"),
  /// or empty when nothing is known. Only known parts are shown.
  String get displayLine {
    final parts = <String>[];
    final r = remaining;
    if (r != null) {
      final gb = r < 0 ? 0.0 : r / 1e9;
      parts.add('ကျန်: ${gb.toStringAsFixed(1)} GB');
    }
    final e = expireAt;
    if (e != null) {
      parts.add(
          'ကုန်ဆုံးရက်: ${e.year}-${e.month.toString().padLeft(2, '0')}-${e.day.toString().padLeft(2, '0')}');
    }
    return parts.join(' • ');
  }

  factory SubscriptionUserInfo.fromHeader(String? header) {
    var upload = 0;
    var download = 0;
    var total = 0;
    var expire = 0;
    if (header != null && header.isNotEmpty) {
      for (final part in header.split(';')) {
        final kv = part.split('=');
        if (kv.length != 2) continue;
        final value = int.tryParse(kv[1].trim()) ?? 0;
        switch (kv[0].trim().toLowerCase()) {
          case 'upload':
            upload = value;
          case 'download':
            download = value;
          case 'total':
            total = value;
          case 'expire':
            expire = value;
        }
      }
    }
    return SubscriptionUserInfo(
      upload: upload,
      download: download,
      total: total,
      expire: expire,
    );
  }

  Map<String, dynamic> toJson() => {
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire,
      };

  factory SubscriptionUserInfo.fromJson(Map<String, dynamic> j) =>
      SubscriptionUserInfo(
        upload: (j['upload'] as num?)?.toInt() ?? 0,
        download: (j['download'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        expire: (j['expire'] as num?)?.toInt() ?? 0,
      );
}

/// What one subscription fetch returns: the servers plus, when the
/// server reports it, the usage info from the response header.
class SubscriptionFetch {
  final List<VpnServer> servers;
  final SubscriptionUserInfo? userinfo;

  const SubscriptionFetch({required this.servers, this.userinfo});
}

/// Fetches a subscription file and parses the servers in it.
class SubscriptionService {
  static const _timeout = Duration(seconds: 20);

  /// The free-list subscription id (same value as AppStore.freeSubId —
  /// kept as a literal here so this service does not import AppStore,
  /// which itself imports this service).
  static const _freeSubId = 'free';

  /// v1.0.7 — FREE servers, read DIRECTLY from the "AMKT Free Servers"
  /// Google Sheet (published as CSV, see [AmktConfig.freeServersSheetCsvUrl]).
  /// Tries the Sheet first; when the Sheet cannot be read (or yields no
  /// servers), falls back to the GitHub amkt-free.txt file, so the free
  /// list never goes empty because of one failed fetch. Never throws —
  /// a total failure returns an empty list (the caller keeps the cache).
  static Future<List<VpnServer>> fetchFreeServers() async {
    try {
      final fromSheet = await fetchFreeServersFromSheet();
      if (fromSheet.isNotEmpty) return fromSheet;
    } catch (_) {
      // fall through to the GitHub fallback
    }
    try {
      return await fetchServers(AmktConfig.defaultFreeSubscriptionUrl,
          subscriptionId: _freeSubId);
    } catch (_) {
      return const [];
    }
  }

  /// Reads the free-server Sheet as CSV and returns its servers.
  /// The Sheet's columns are: # | Name | Country | Protocol | Address |
  /// Port | Network/Method | TLS/Security | Link — only the Link column
  /// is used (the header row is skipped; the Link column is found by
  /// its header name, falling back to the last column). Throws when the
  /// fetch fails or no links are found.
  static Future<List<VpnServer>> fetchFreeServersFromSheet() async {
    final res = await http
        .get(Uri.parse(AmktConfig.freeServersSheetCsvUrl),
            headers: {'User-Agent': 'AmktVPN/1.0'})
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Sheet error: HTTP ${res.statusCode}');
    }
    final links = _extractLinkColumn(res.body);
    if (links.isEmpty) throw const FormatException('Sheet has no links');
    return VpnServer.parseSubscriptionBody(links.join('\n'),
        subscriptionId: _freeSubId);
  }

  /// Extracts the Link column from a Sheet CSV export. Handles quoted
  /// fields (a field wrapped in "..." may contain commas or newlines;
  /// "" inside quotes is one literal quote). Returns the non-empty
  /// Link values of the data rows (header row skipped).
  static List<String> _extractLinkColumn(String csv) {
    final rows = _parseCsvRows(csv);
    if (rows.isEmpty) return const [];
    // Find the Link column by header name; fall back to the last column.
    var linkIdx = rows.first.length - 1;
    for (var i = 0; i < rows.first.length; i++) {
      if (rows.first[i].trim().toLowerCase() == 'link') {
        linkIdx = i;
        break;
      }
    }
    final out = <String>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= linkIdx) continue;
      final link = row[linkIdx].trim();
      if (link.isNotEmpty) out.add(link);
    }
    return out;
  }

  /// Minimal CSV parser: rows split on newlines, fields on commas,
  /// double-quoted fields may contain commas / newlines / "" escapes.
  static List<List<String>> _parseCsvRows(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field = StringBuffer();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field = StringBuffer();
        // Skip a trailing empty row (final newline).
        if (row.length == 1 && row.first.isEmpty) {
          row = <String>[];
          continue;
        }
        rows.add(row);
        row = <String>[];
      } else {
        field.write(c);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  /// Returns the servers found at [url], or throws with a short message.
  static Future<List<VpnServer>> fetchServers(String url,
      {required String subscriptionId}) async {
    final fetch = await fetchWithInfo(url, subscriptionId: subscriptionId);
    return fetch.servers;
  }

  /// Same as [fetchServers], but also captures the Marzban
  /// `subscription-userinfo` response header when the server sends it.
  /// [userinfo] is null when the server reports no usage info.
  static Future<SubscriptionFetch> fetchWithInfo(String url,
      {required String subscriptionId}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const FormatException('URL မမှန်ပါ (http/https ဖြစ်ရမယ်)');
    }
    final res = await http
        .get(uri, headers: {'User-Agent': 'AmktVPN/1.0'})
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('Server error: HTTP ${res.statusCode}');
    }
    final servers = VpnServer.parseSubscriptionBody(res.body,
        subscriptionId: subscriptionId);
    final info = SubscriptionUserInfo.fromHeader(
        res.headers['subscription-userinfo']);
    return SubscriptionFetch(
      servers: servers,
      userinfo: info.hasAny ? info : null,
    );
  }
}
