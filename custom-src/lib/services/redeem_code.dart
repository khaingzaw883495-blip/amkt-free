import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'app_store.dart';

/// Result of one code validation against the n8n validator webhook.
class CodeValidation {
  final bool valid;
  final DateTime? expiresAt;
  final String message;

  const CodeValidation({
    required this.valid,
    this.expiresAt,
    required this.message,
  });
}

/// No-ads redeem codes (AMKT-XXXX-XXXX), issued by the Telegram bot.
///
/// Validator: POST https://n8n.marratethu.web.id/webhook/amkt-noads-validate
/// with {"code", "device_id"} → {"valid", "expires_at", "message"}.
/// Rules (server side): an unused code binds to the calling device and
/// expires 30 days from first use; the same device again is valid; a
/// different device is invalid; expired / revoked / unknown codes are
/// invalid; codes are case-insensitive and trimmed.
///
/// Fail-closed: any non-JSON / empty response (this happens while the
/// code sheet is empty — the validator returns an empty HTTP 200), any
/// network error, or any missing field is treated as INVALID, so ads
/// stay on. The app never invents a valid code.
class NoAdsCodeService {
  static const _timeout = Duration(seconds: 15);

  /// Validates [code] for this device. Returns the validation result.
  /// Never throws — every failure path returns valid: false.
  static Future<CodeValidation> validateCode(
      AppStore store, String code) async {
    final clean = code.trim().toUpperCase();
    if (clean.isEmpty) {
      return const CodeValidation(
          valid: false, message: 'ကုတ် ထည့်ပါ');
    }
    try {
      final deviceId = await store.getOrCreateDeviceId();
      final res = await http
          .post(
            Uri.parse(AmktConfig.noAdsValidateUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': clean, 'device_id': deviceId}),
          )
          .timeout(_timeout);
      // Empty body (HTTP 200 with no JSON) = invalid. Fail closed.
      if (res.body.trim().isEmpty) {
        return const CodeValidation(
            valid: false, message: 'ကုတ် စစ်မရပါ — နောက်မှ ထပ်စမ်းပါ');
      }
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        return const CodeValidation(
            valid: false, message: 'ကုတ် စစ်မရပါ — နောက်မှ ထပ်စမ်းပါ');
      }
      final valid = j['valid'] == true;
      DateTime? expiresAt;
      final expRaw = j['expires_at'];
      if (expRaw is String && expRaw.isNotEmpty) {
        expiresAt = DateTime.tryParse(expRaw);
      }
      if (!valid) {
        final msg = (j['message'] as String?)?.trim();
        return CodeValidation(
            valid: false,
            message: msg != null && msg.isNotEmpty ? msg : 'ကုတ် မမှန်ပါ');
      }
      // A "valid" answer without a usable expiry is not trusted.
      if (expiresAt == null || !expiresAt.isAfter(DateTime.now())) {
        return const CodeValidation(
            valid: false, message: 'ကုတ် သက်တမ်း ကုန်နေပါပြီ');
      }
      return CodeValidation(
          valid: true, expiresAt: expiresAt, message: 'ကုတ် မှန်ပါတယ်');
    } catch (_) {
      return const CodeValidation(
          valid: false, message: 'အင်တာနက် မရပါ — နောက်မှ ထပ်စမ်းပါ');
    }
  }

  /// Validates [code] and, when valid, stores it on the device.
  /// Returns the validation result (stored only when valid).
  static Future<CodeValidation> redeemCode(
      AppStore store, String code) async {
    final result = await validateCode(store, code);
    if (result.valid) {
      await store.saveNoAdsCode(code, result.expiresAt);
    }
    return result;
  }

  /// Re-validates the stored code (app start). When the server says
  /// invalid (revoked, expired, bound to another phone), the stored
  /// code is cleared so ads come back. Network errors leave the stored
  /// code alone (a failed check is not proof the code is bad).
  static Future<void> revalidateStoredCode(AppStore store) async {
    final code = store.noAdsCode;
    if (code == null || code.isEmpty) return;
    try {
      final deviceId = await store.getOrCreateDeviceId();
      final res = await http
          .post(
            Uri.parse(AmktConfig.noAdsValidateUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'device_id': deviceId}),
          )
          .timeout(_timeout);
      if (res.body.trim().isEmpty) return; // cannot tell — keep code
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final valid = j['valid'] == true;
      DateTime? expiresAt;
      final expRaw = j['expires_at'];
      if (expRaw is String && expRaw.isNotEmpty) {
        expiresAt = DateTime.tryParse(expRaw);
      }
      if (!valid ||
          expiresAt == null ||
          !expiresAt.isAfter(DateTime.now())) {
        await store.clearNoAdsCode();
      } else {
        // Refresh the stored expiry (the server is the source of truth).
        await store.saveNoAdsCode(code, expiresAt);
      }
    } catch (_) {
      // Offline / server error — keep the stored code.
    }
  }
}
