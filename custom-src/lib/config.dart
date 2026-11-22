/// Amkt VPN — app-wide constants.
///
/// Everything the user can change later lives in Settings (stored in
/// SharedPreferences); the values here are only the defaults.
class AmktConfig {
  /// Default FREE subscription URL (embedded in the app).
  ///
  /// Public repo (created by Amkt, 2026-11-10):
  /// https://github.com/khaingzaw883495-blip/amkt-free
  /// v1.0.7 — this GitHub file is now only the FALLBACK. The free list
  /// is read DIRECTLY from the "AMKT Free Servers" Google Sheet (see
  /// [freeServersSheetCsvUrl]).
  static const String defaultFreeSubscriptionUrl =
      'https://raw.githubusercontent.com/khaingzaw883495-blip/amkt-free/main/amkt-free.txt';

  /// v1.0.7 — FREE servers, read DIRECTLY from the "AMKT Free Servers"
  /// Google Sheet (published as CSV).
  static const String freeServersSheetCsvUrl =
      'https://docs.google.com/spreadsheets/d/1rJPmAULZqM9M4gICys_EQxUGDGhHmRB2l9DG_xTFR9k/export?format=csv&gid=0';

  /// Contact / support.
  static const String telegramUrl = 'https://t.me/amktvpn';

  /// Free-tier ads: shown FIRST in external browser, then the app waits
  /// [freeConnectDelaySeconds] (7s) and only then connects.
  /// Paid users (valid code or own Marzban subscription) never see these.
  static const String adLinkUrl =
      'https://asiafilm.org/4/e7bc65934a2fb9eef0e7b8c88cef974e';
  static const String adBannerKey = 'fe46d0afda2f021f7659b690e452eff4';
  static const String adBannerScriptUrl =
      'https://bellnewyork.org/22/fe46d0afda2f021f7659b690e452eff4';
  static const int freeConnectDelaySeconds = 7;

  /// Remote ad config (fetched on app start, cached locally).
  static const String adsJsonUrl =
      'https://raw.githubusercontent.com/khaingzaw883495-blip/amkt-free/main/ads.json';

  /// No-ads redeem code: validator webhook (n8n).
  static const String noAdsValidateUrl =
      'https://n8n.marratethu.web.id/webhook/amkt-noads-validate';

  /// Buyer-only server list (code-gated).
  static const String buyerServersUrl =
      'https://n8n.marratethu.web.id/webhook/amkt-noads-buyer-servers';

  /// Own-subscription detection (v1.0.8): a subscription URL whose host
  /// is in this set is Amkt's own Marzban panel — its buyer gets paid
  /// treatment (no ads, no 7-second wait, no time credit).
  static const Set<String> ownSubscriptionHosts = {
    'overcrowd-degree-reliant.ngrok-free.dev',
  };

  /// This build's own version (must match pubspec.yaml).
  static const String currentVersion = '1.0.10';
  static const int currentVersionCode = 11;

  /// In-app update check: version.json in the same GitHub repo.
  static const String updateJsonUrl =
      'https://raw.githubusercontent.com/khaingzaw883495-blip/amkt-free/main/version.json';
}
