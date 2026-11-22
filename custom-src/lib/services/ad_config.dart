import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// One ad setup: the link opened before connecting (free tier) and the
/// 320x50 banner shown while the 5-second wait runs.
class AdConfig {
  final String adLink;
  final String bannerKey;
  final String bannerScriptUrl;

  /// Image-fallback banner (optional): when the script banner fails to
  /// load, the app shows this remote image + title instead, and tapping
  /// it opens [bannerImageLink] (or [adLink] when unset — Adsterra
  /// slot only). The own-ad banner ([OwnAdBanner]) never falls back to
  /// [adLink]: its tap opens [bannerImageLink], or the channel URL
  /// (t.me/amktvpn) when the remote config has not loaded yet. All
  /// three come from ads.json; when absent, a failed script banner
  /// just hides.
  final String? bannerImageUrl;
  final String? bannerImageTitle;
  final String? bannerImageLink;

  /// True when these values came from the remote ads.json file.
  final bool isRemote;

  const AdConfig({
    required this.adLink,
    required this.bannerKey,
    required this.bannerScriptUrl,
    this.bannerImageUrl,
    this.bannerImageTitle,
    this.bannerImageLink,
    this.isRemote = false,
  });

  static const defaults = AdConfig(
    adLink: AmktConfig.adLinkUrl,
    bannerKey: AmktConfig.adBannerKey,
    bannerScriptUrl: AmktConfig.adBannerScriptUrl,
  );

  Map<String, dynamic> toJson() => {
        'ad_link': adLink,
        'banner_key': bannerKey,
        'banner_script_url': bannerScriptUrl,
        'banner_image_url': bannerImageUrl,
        'banner_image_title': bannerImageTitle,
        'banner_image_link': bannerImageLink,
      };

  factory AdConfig.fromJson(Map<String, dynamic> j) => AdConfig(
        adLink: (j['ad_link'] as String?)?.trim().isNotEmpty == true
            ? (j['ad_link'] as String).trim()
            : AmktConfig.adLinkUrl,
        bannerKey: (j['banner_key'] as String?)?.trim().isNotEmpty == true
            ? (j['banner_key'] as String).trim()
            : AmktConfig.adBannerKey,
        bannerScriptUrl:
            (j['banner_script_url'] as String?)?.trim().isNotEmpty == true
                ? (j['banner_script_url'] as String).trim()
                : AmktConfig.adBannerScriptUrl,
        bannerImageUrl: _optStr(j['banner_image_url']),
        bannerImageTitle: _optStr(j['banner_image_title']),
        bannerImageLink: _optStr(j['banner_image_link']),
        isRemote: true,
      );

  static String? _optStr(Object? v) {
    final s = (v as String?)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Origin of the ad network (e.g. https://bellnewyork.org) — the base
  /// URL the banner HTML is loaded with (loadDataWithBaseURL semantics).
  /// The invoke.js script only renders when it runs with its own network
  /// as the base URL.
  String get bannerBaseUrl =>
      Uri.tryParse(bannerScriptUrl)?.origin ?? '';

  /// 320x50 banner ad HTML rendered in a WebView on the connect screen.
  String get bannerHtml => '''
<!DOCTYPE html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{margin:0;padding:0;background:transparent;display:flex;justify-content:center;}</style>
</head><body>
<script type="text/javascript">
  atOptions = {'key' : '$bannerKey', 'format' : 'iframe', 'height' : 50, 'width' : 320, 'params' : {}};
</script>
<script type="text/javascript" src="$bannerScriptUrl"></script>
</body></html>
''';
}

/// Remotely configurable ads.
///
/// On app start the app fetches ads.json from the same public GitHub repo
/// (see [AmktConfig.adsJsonUrl]). The file is a small JSON object:
///
///   {"ad_link": "https://...", "banner_key": "...",
///    "banner_script_url": "https://...",
///    "banner_image_url": "https://... (optional fallback image)",
///    "banner_image_title": "... (optional)",
///    "banner_image_link": "https://... (optional, tap target)"}
///
/// Any field missing from the file keeps its built-in default (the image
/// fields stay unset when missing). When the file is missing (404) or
/// unreachable, the last cached config is used, and if there is no cache
/// the built-in defaults are used — so ads never break the app. She
/// changes ads by editing ads.json in the repo; no app rebuild is needed.
class AdConfigService {
  static const _kCache = 'ad_config_cache';

  /// The config currently in effect (defaults until [refresh] runs).
  static AdConfig current = AdConfig.defaults;

  /// Widgets showing the remote config (e.g. the own-ad banner) can
  /// register here to rebuild when [refresh] finishes. The first build
  /// usually happens before the background fetch lands, and the
  /// built-in defaults have no banner image/link — without this, the
  /// own-ad banner would stay stuck on its text fallback and its tap
  /// would fall back to the Adsterra link for the whole session
  /// (v1.0.7 fix 2b).
  static final _listeners = <void Function()>[];
  static void addListener(void Function() cb) => _listeners.add(cb);
  static void removeListener(void Function() cb) => _listeners.remove(cb);
  static void _notifyListeners() {
    for (final cb in List<void Function()>.of(_listeners)) {
      try {
        cb();
      } catch (_) {}
    }
  }

  static Future<void> refresh() async {
    try {
      final res = await http
          .get(Uri.parse(AmktConfig.adsJsonUrl),
              headers: {'User-Agent': 'AmktVPN/1.0'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final cfg =
            AdConfig.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
        current = cfg;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kCache, jsonEncode(cfg.toJson()));
        _notifyListeners();
        return;
      }
    } catch (_) {
      // fall through to cache / defaults
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCache);
      if (raw != null && raw.isNotEmpty) {
        current = AdConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        _notifyListeners();
        return;
      }
    } catch (_) {
      // fall through to defaults
    }
    current = AdConfig.defaults;
    _notifyListeners();
  }
}
