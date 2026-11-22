import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// One newer release, read from version.json in the GitHub repo.
class AppUpdateInfo {
  final String version;
  final int versionCode;
  final String apkUrl;
  final String notes;

  const AppUpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.notes,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> j) => AppUpdateInfo(
        version: (j['version'] as String? ?? '').trim(),
        versionCode: (j['version_code'] as num?)?.toInt() ?? 0,
        apkUrl: (j['apk_url'] as String? ?? '').trim(),
        notes: (j['notes'] as String? ?? '').trim(),
      );
}

/// In-app update: silent version check on app start, in-app APK download,
/// then the Android install prompt. Any failure is silent — the app
/// keeps working normally and never blocks the user.
class AppUpdateService {
  static const _channel = MethodChannel('amktvpn/install');

  /// Returns the newer release when one exists, else null.
  /// Never throws.
  static Future<AppUpdateInfo?> checkForUpdate() async {
    try {
      final res = await http
          .get(Uri.parse(AmktConfig.updateJsonUrl),
              headers: {'User-Agent': 'AmktVPN/1.0'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final info =
          AppUpdateInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      if (info.versionCode > AmktConfig.currentVersionCode &&
          info.apkUrl.isNotEmpty) {
        return info;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Android 8+: can this app install APKs (the "install unknown apps"
  /// permission)? True on older Android.
  static Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "install unknown apps" settings page for this app.
  static Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {
      // nothing to do — the dialog explains manual install instead
    }
  }

  /// Downloads the APK to the app cache dir, reporting progress.
  /// [onProgress] gets (bytesReceived, totalBytesOrNull).
  /// Returns the local file path. Throws on failure.
  ///
  /// v1.0.7 — FileProvider bug fix: the download MUST go to the real
  /// cache dir (`getTemporaryDirectory()` → getCacheDir()), because
  /// `filepaths.xml` only exposes `<cache-path>` (the real cache
  /// folder). The old code used `Directory.systemTemp`, which on
  /// Android is the *code_cache* folder — FileProvider could not hand
  /// that file to the installer ("Failed to find configured root that
  /// contains .../code_cache/amkt-vpn-update.apk"), so every in-app
  /// update failed at the install step even though the download had
  /// succeeded.
  static Future<String> downloadApk(
    String url,
    void Function(int received, int? total) onProgress,
  ) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final len = res.contentLength;
      final total = len != null && len > 0 ? len : null;
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/amkt-vpn-update.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress(received, total);
      }
      await sink.close();
      return file.path;
    } finally {
      client.close();
    }
  }

  /// Opens the Android package installer for the downloaded APK.
  static Future<void> installApk(String path) async {
    await _channel.invokeMethod('installApk', {'path': path});
  }
}
