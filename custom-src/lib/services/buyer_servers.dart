import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/vpn_server.dart';
import 'app_store.dart';

/// Buyer-only server list (code-gated).
///
/// The paid servers must NOT come from the public GitHub free file
/// (amkt-free.txt) — that file is public, anyone can read it. Instead
/// the app fetches them from a protected n8n webhook that checks the
/// code first. The endpoint does NOT exist yet (2026-11-12); until the
/// backend is built, this returns an empty list and the buyer section
/// simply stays hidden.
///
/// BACKEND CONTRACT (what n8n must provide):
///   POST the buyer endpoint URL (default:
///   `https://n8n.marratethu.web.id/webhook/amkt-noads-buyer-servers`)
///   Body: `{"code": "AMKT-XXXX-XXXX", "device_id": "<device id>"}`
///   Success (HTTP 200, JSON):
///     `{"servers": ["vless://...", "vmess://...", ...]}`
///     (`{"links": [...]}` is accepted as an alias.)
///   OR success as a plain subscription body: one share link per line,
///   optionally base64-encoded — the same format as a subscription file.
///   The endpoint must validate the code + device itself (same rules as
///   the validate webhook: unused binds, same device valid, other
///   device / expired / revoked / unknown invalid) and must NEVER
///   return servers for an invalid code.
///   Any other status, empty body, unparsable body, or empty list →
///   no buyer servers (the section stays hidden).
///
/// KEY ROTATION (the user's rule, 2026-11-12): the paid key lives ONLY
/// on the backend list — never hardcoded in the app. The app re-fetches
/// the list from the protected endpoint on every refresh, so when the
/// user deletes a leaked key and swaps in a new one (update the backend
/// list + delete/rotate the key on the server/panel — no app rebuild),
/// the app picks up the new key on its next refresh and the old key
/// stops being served. A failed fetch (offline / endpoint down) keeps
/// the last good cache instead of wiping it — only a successful fetch
/// replaces the list. Honest limit: changing the served list stops the
/// app showing the old key, but fully killing a leaked key also needs
/// it deleted/rotated on the server/panel itself.
///
/// HONEST LIMIT: code-gating stops ordinary users from seeing the
/// servers in the app. A determined technical user could still extract
/// a link from their own device's traffic. The real protection is
/// per-user codes bound to one device plus the ability to rotate or
/// revoke keys on the panel — the app does not claim the servers
/// cannot leak.
class BuyerServersService {
  static const _timeout = Duration(seconds: 20);

  /// Fetches the buyer-only servers for a valid code. Returns the
  /// parsed servers (possibly empty when the endpoint legitimately
  /// serves none), or null when the fetch FAILED (offline / endpoint
  /// down / bad response) — the caller keeps the last good cache on
  /// null. Never throws, never logs links.
  static Future<List<VpnServer>?> fetchBuyerServers(
      AppStore store) async {
    final code = store.noAdsCode;
    if (code == null || code.isEmpty || !store.hasNoAdsAccess) {
      return const [];
    }
    try {
      final deviceId = await store.getOrCreateDeviceId();
      final res = await http
          .post(
            Uri.parse(AmktConfig.buyerServersUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'device_id': deviceId}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200 || res.body.trim().isEmpty) {
        return null;
      }
      // JSON form first: {"servers": [...]} or {"links": [...]}.
      try {
        final j = jsonDecode(res.body);
        if (j is Map<String, dynamic>) {
          final rawList = j['servers'] ?? j['links'];
          if (rawList is List) {
            return rawList
                .map((e) => VpnServer.parseShareLink(e.toString(),
                    subscriptionId: AppStore.buyerSubId))
                .whereType<VpnServer>()
                .toList();
          }
          return null;
        }
      } catch (_) {
        // Not JSON — fall through to plain subscription body parsing.
      }
      return VpnServer.parseSubscriptionBody(res.body,
          subscriptionId: AppStore.buyerSubId);
    } catch (_) {
      return null;
    }
  }

  /// Refreshes the buyer cache (called after a code is redeemed and
  /// on Home refresh). Only a SUCCESSFUL fetch replaces the cache —
  /// a failed fetch leaves the last good list in place, so a network
  /// hiccup never wipes the buyer section. Never throws.
  static Future<void> refreshBuyerServers(AppStore store) async {
    try {
      final servers = await fetchBuyerServers(store);
      if (servers != null) {
        await store.saveServers(AppStore.buyerSubId, servers);
      }
    } catch (_) {
      // Buyer servers are best-effort — never break the app for them.
    }
  }
}
