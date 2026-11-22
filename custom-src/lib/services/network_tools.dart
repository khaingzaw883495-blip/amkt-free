import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Public IP and country detected after connecting to the VPN.
class IpInfo {
  final String ip;
  final String country;
  final String countryCode;

  const IpInfo({
    required this.ip,
    required this.country,
    required this.countryCode,
  });

  String get countryFlag {
    final code = countryCode.toUpperCase();
    if (code.length != 2) return '🌐';
    return String.fromCharCodes(
      code.codeUnits.map((c) => 0x1F1E6 + c - 0x41),
    );
  }
}

/// Live progress snapshot emitted during an on-demand speedtest.
class SpeedtestProgress {
  final String stage; // 'ping', 'download', 'upload', 'done', 'error'
  final double progress; // 0.0 .. 1.0
  final int? pingMs;
  final double? downloadMbps;
  final double? uploadMbps;
  final String? error;

  const SpeedtestProgress({
    required this.stage,
    required this.progress,
    this.pingMs,
    this.downloadMbps,
    this.uploadMbps,
    this.error,
  });
}

/// Network tools: post-connect IP + country lookup and on-demand speedtest.
class NetworkToolsService {
  NetworkToolsService._();

  /// Fetches the current public IP and country. Never throws; returns null
  /// if all endpoints fail or time out.
  static Future<IpInfo?> fetchPublicIp() async {
    // Primary: ipwho.is (HTTPS, no key needed)
    try {
      final res = await http
          .get(
            Uri.parse('https://ipwho.is/'),
            headers: {'User-Agent': 'AmktVPN/1.0'},
          )
          .timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final ip = (j['ip'] as String?)?.trim() ?? '';
        final country = (j['country'] as String?)?.trim() ?? '';
        final code = (j['country_code'] as String?)?.trim() ?? '';
        if (ip.isNotEmpty) {
          return IpInfo(
            ip: ip,
            country: country.isEmpty ? code : country,
            countryCode: code,
          );
        }
      }
    } catch (_) {}

    // Fallback: ipapi.co
    try {
      final res = await http
          .get(
            Uri.parse('https://ipapi.co/json/'),
            headers: {'User-Agent': 'AmktVPN/1.0'},
          )
          .timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final ip = (j['ip'] as String?)?.trim() ?? '';
        final country = (j['country_name'] as String?)?.trim() ?? '';
        final code = (j['country_code'] as String?)?.trim() ?? '';
        if (ip.isNotEmpty) {
          return IpInfo(
            ip: ip,
            country: country.isEmpty ? code : country,
            countryCode: code,
          );
        }
      }
    } catch (_) {}

    return null;
  }

  /// On-demand speedtest (ONLY runs when user explicitly taps the button).
  /// Measures Ping (ms), Download (Mbps), and Upload (Mbps) using Cloudflare's
  /// speed endpoints. Calls [onProgress] at each stage and returns the final
  /// snapshot. Never throws.
  static Future<SpeedtestProgress> runSpeedtest({
    void Function(SpeedtestProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = http.Client();
    int? pingMs;
    double? downloadMbps;
    double? uploadMbps;

    bool cancelled() => isCancelled?.call() ?? false;

    try {
      // 1. Ping (average of 3 lightweight HEAD/GET requests)
      onProgress?.call(const SpeedtestProgress(stage: 'ping', progress: 0.1));
      final pingSamples = <int>[];
      for (var i = 0; i < 3; i++) {
        if (cancelled()) {
          return const SpeedtestProgress(
              stage: 'error', progress: 0, error: 'ပယ်ဖျက်လိုက်ပြီ');
        }
        final sw = Stopwatch()..start();
        final res = await client
            .get(Uri.parse('https://speed.cloudflare.com/__down?bytes=0'))
            .timeout(const Duration(seconds: 6));
        sw.stop();
        if (res.statusCode == 200) {
          pingSamples.add(sw.elapsedMilliseconds);
        }
      }
      if (pingSamples.isEmpty) {
        const err = SpeedtestProgress(
          stage: 'error',
          progress: 0,
          error: 'Ping စစ်မရပါ — အင်တာနက် စစ်ပါ',
        );
        onProgress?.call(err);
        return err;
      }
      pingSamples.sort();
      pingMs = pingSamples[pingSamples.length ~/ 2]; // median
      onProgress?.call(SpeedtestProgress(
        stage: 'download',
        progress: 0.3,
        pingMs: pingMs,
      ));

      if (cancelled()) {
        return const SpeedtestProgress(
            stage: 'error', progress: 0, error: 'ပယ်ဖျက်လိုက်ပြီ');
      }

      // 2. Download test (~5 MB streamed for live speed updates)
      const downloadBytesTarget = 5 * 1024 * 1024;
      final dlReq = http.Request(
        'GET',
        Uri.parse(
            'https://speed.cloudflare.com/__down?bytes=$downloadBytesTarget'),
      );
      final dlSw = Stopwatch()..start();
      final dlRes =
          await client.send(dlReq).timeout(const Duration(seconds: 15));
      var received = 0;
      await for (final chunk in dlRes.stream.timeout(
        const Duration(seconds: 15),
      )) {
        if (cancelled()) {
          client.close();
          return const SpeedtestProgress(
              stage: 'error', progress: 0, error: 'ပယ်ဖျက်လိုက်ပြီ');
        }
        received += chunk.length;
        final secs = dlSw.elapsedMilliseconds / 1000.0;
        if (secs > 0.15) {
          downloadMbps = (received * 8) / (secs * 1000000);
          final frac = (received / downloadBytesTarget).clamp(0.0, 1.0);
          onProgress?.call(SpeedtestProgress(
            stage: 'download',
            progress: 0.3 + frac * 0.4,
            pingMs: pingMs,
            downloadMbps: downloadMbps,
          ));
        }
      }
      dlSw.stop();
      if (received > 0 && dlSw.elapsedMilliseconds > 0) {
        downloadMbps =
            (received * 8) / ((dlSw.elapsedMilliseconds / 1000.0) * 1000000);
      }

      if (cancelled()) {
        return const SpeedtestProgress(
            stage: 'error', progress: 0, error: 'ပယ်ဖျက်လိုက်ပြီ');
      }

      // 3. Upload test (1 MB payload)
      onProgress?.call(SpeedtestProgress(
        stage: 'upload',
        progress: 0.75,
        pingMs: pingMs,
        downloadMbps: downloadMbps,
      ));
      const uploadSize = 1024 * 1024;
      final payload = Uint8List(uploadSize);
      final ulSw = Stopwatch()..start();
      final ulRes = await client
          .post(
            Uri.parse('https://speed.cloudflare.com/__up'),
            body: payload,
            headers: {'Content-Type': 'application/octet-stream'},
          )
          .timeout(const Duration(seconds: 15));
      ulSw.stop();
      if (ulRes.statusCode >= 200 &&
          ulRes.statusCode < 300 &&
          ulSw.elapsedMilliseconds > 0) {
        uploadMbps =
            (uploadSize * 8) / ((ulSw.elapsedMilliseconds / 1000.0) * 1000000);
      }

      final done = SpeedtestProgress(
        stage: 'done',
        progress: 1.0,
        pingMs: pingMs,
        downloadMbps: downloadMbps,
        uploadMbps: uploadMbps,
      );
      onProgress?.call(done);
      return done;
    } catch (_) {
      final err = SpeedtestProgress(
        stage: 'error',
        progress: 0,
        pingMs: pingMs,
        downloadMbps: downloadMbps,
        uploadMbps: uploadMbps,
        error: 'Speedtest စစ်မရပါ — ချိတ်ဆက်မှု စစ်ပြီး ပြန်စမ်းပါ',
      );
      onProgress?.call(err);
      return err;
    } finally {
      client.close();
    }
  }
}
