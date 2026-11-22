import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config.dart';
import '../services/ad_config.dart';

/// 320x50 banner ad (free tier only).
///
/// Method follows Voice-Ai's working banner (method only — no Voice-Ai
/// code was copied):
/// - WebView, JavaScript unrestricted (DOM storage is on by default in
///   webview_flutter on Android), transparent background, real Chrome
///   Mobile user agent. The ad network returns an EMPTY script for
///   non-browser user agents (verified: curl's default UA got 0 bytes,
///   a Chrome Mobile UA got the real 59 KB banner script) — that is why
///   the banner never showed in the earlier app.
/// - The Adsterra invoke.js embed (atOptions + script tag) is loaded with
///   loadDataWithBaseURL semantics: `loadHtmlString(html, baseUrl: <ad
///   network origin>)`. The script only renders when it runs with its
///   own network as the base URL.
/// - Image fallback branch: when the script fails to load (or no script
///   is configured), the app shows the remote banner image from ads.json
///   (banner_image_url + title + tap link) instead. When that is absent
///   too, the slot collapses to nothing rather than an empty box.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  WebViewController? _controller;
  bool _scriptFailed = false;
  bool _loaded = false;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    final cfg = AdConfigService.current;
    if (cfg.bannerScriptUrl.trim().isEmpty ||
        cfg.bannerKey.trim().isEmpty) {
      // No script configured — straight to the image fallback.
      _scriptFailed = true;
      return;
    }
    final baseUrl =
        cfg.bannerBaseUrl.isEmpty ? null : cfg.bannerBaseUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _fallbackTimer?.cancel();
            if (mounted) setState(() => _loaded = true);
          },
          onWebResourceError: (_) {
            _fallbackTimer?.cancel();
            if (mounted) setState(() => _scriptFailed = true);
          },
        ),
      )
      ..loadHtmlString(cfg.bannerHtml, baseUrl: baseUrl);
    // The ad script sometimes never calls back at all: fall back to the
    // image branch after 10s instead of leaving a blank box.
    _fallbackTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && !_loaded) setState(() => _scriptFailed = true);
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AdConfigService.current;
    if (_scriptFailed) {
      final imageUrl = cfg.bannerImageUrl;
      if (imageUrl == null || imageUrl.isEmpty) {
        return const SizedBox.shrink();
      }
      return _imageFallback(cfg, imageUrl);
    }
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return Container(
      width: 320,
      height: 50,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: WebViewWidget(controller: controller),
    );
  }

  Widget _imageFallback(AdConfig cfg, String imageUrl) {
    final link = cfg.bannerImageLink ?? cfg.adLink;
    final title = cfg.bannerImageTitle;
    return InkWell(
      onTap: () => launchUrl(Uri.parse(link),
          mode: LaunchMode.externalApplication),
      child: Container(
        width: 320,
        height: 50,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            if (title != null && title.isNotEmpty)
              Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  color: Colors.black54,
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The AMKT channel's OWN ad banner (v1.0.7) — the dedicated second
/// banner slot. Unlike [AdBanner] this one is shown to EVERYONE: free
/// users see it under the Adsterra banner, and buyers (valid no-ads
/// code) see ONLY this one (no Adsterra). It uses the banner image from
/// ads.json (`banner_image_url`, the AMKT shield banner) and taps
/// through to `banner_image_link` (t.me/amktvpn). When the image is
/// missing or fails to load, a built-in text banner (shield + AMKT VPN
/// + t.me/amktvpn) is shown instead, so the slot never collapses to
/// nothing. v1.0.7 fix — NO "AD" badge on this banner (her word
/// 2026-11-17); only the Adsterra banner is labelled as an ad.
///
/// Stateful so it rebuilds when the remote ads.json fetch lands: the
/// fetch runs in the background at startup, so the first build usually
/// uses the built-in defaults (no image, no link). v1.0.7 fix 2b — the
/// tap NEVER opens the Adsterra ad link: it opens `banner_image_link`
/// (t.me/amktvpn), falling back to the channel URL when the remote
/// config has not loaded yet. (Previously the fallback was
/// `cfg.adLink`, so tapping the own-ad before ads.json arrived popped
/// up the Adsterra link box instead of Telegram.)
class OwnAdBanner extends StatefulWidget {
  const OwnAdBanner({super.key});

  @override
  State<OwnAdBanner> createState() => _OwnAdBannerState();
}

class _OwnAdBannerState extends State<OwnAdBanner> {
  @override
  void initState() {
    super.initState();
    AdConfigService.addListener(_onAdConfigChanged);
  }

  @override
  void dispose() {
    AdConfigService.removeListener(_onAdConfigChanged);
    super.dispose();
  }

  void _onAdConfigChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AdConfigService.current;
    final imageUrl = cfg.bannerImageUrl;
    final link = cfg.bannerImageLink ?? AmktConfig.telegramUrl;
    return InkWell(
      onTap: () => launchUrl(Uri.parse(link),
          mode: LaunchMode.externalApplication),
      child: Container(
        width: 320,
        height: 50,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1A3A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: const Color(0xFF8B5CF6).withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _builtInOwnAd(),
              )
            else
              _builtInOwnAd(),
          ],
        ),
      ),
    );
  }

  /// Built-in fallback: shield + "AMKT VPN" + t.me/amktvpn, used when
  /// the remote banner image is missing or fails to load.
  Widget _builtInOwnAd() {
    return Container(
      color: const Color(0xFF1E1A3A),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF8B5CF6), Color(0xFF22D3EE)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.bolt, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          const Text(
            'AMKT VPN',
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Text(
            't.me/amktvpn',
            style: TextStyle(fontSize: 13, color: Color(0xFF22D3EE)),
          ),
        ],
      ),
    );
  }
}
