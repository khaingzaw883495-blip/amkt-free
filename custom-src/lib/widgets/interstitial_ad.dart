import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/ad_config.dart';

/// Connect ad gate (v1.0.10):
/// Opens the ad link in the external browser (instead of an in-app WebView),
/// and starts the 7-second countdown IMMEDIATELY as soon as the dialog opens.
/// The VPN connects only after the countdown finishes. Closing early (X or
/// back button) returns false and cancels connecting.
/// Paid users (valid no-ads/VIP code or own-panel subscription) skip this.
Future<bool> showConnectAdGate(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _ConnectAdGateDialog(),
  );
  return result ?? false;
}

class _ConnectAdGateDialog extends StatefulWidget {
  const _ConnectAdGateDialog();

  @override
  State<_ConnectAdGateDialog> createState() => _ConnectAdGateDialogState();
}

class _ConnectAdGateDialogState extends State<_ConnectAdGateDialog> {
  static const _waitSeconds = AmktConfig.freeConnectDelaySeconds;
  int _remaining = _waitSeconds;
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Open the ad link in the external browser immediately.
    _openAdInBrowser();
    // Start the 7-second countdown immediately when the dialog opens.
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) _finish(true);
    });
  }

  void _openAdInBrowser() {
    final uri = Uri.tryParse(AdConfigService.current.adLink);
    if (uri == null) return;
    unawaited(
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false),
    );
  }

  void _finish(bool connect) {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    Navigator.of(context).pop(connect);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mutedColor = isDark ? Colors.white70 : Colors.black54;
    final accent = Theme.of(context).colorScheme.secondary;
    final progress = (_waitSeconds - _remaining) / _waitSeconds;

    return PopScope(
      // Back button before the countdown ends = cancel connect.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(false);
      },
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
        title: Row(
          children: [
            Icon(Icons.open_in_browser, color: accent),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'ကြော်ငြာလေး ကြည့်ပေးပါနော်',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'ပိတ်မည်',
              onPressed: () => _finish(false),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              _remaining > 0
                  ? 'ချိတ်ဆက်ဖို့ $_remaining စက္ကန့် စောင့်ပါ…'
                  : 'ချိတ်ဆက်နေတယ်…',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: accent.withValues(alpha: 0.18),
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'ကြော်ငြာကို Browser မှာ ဖွင့်ပေးထားပါတယ် — ၇ စက္ကန့်ပြည့်တာနဲ့ VPN အလိုလို ချိတ်ပေးပါမယ်။',
              style: TextStyle(color: mutedColor, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openAdInBrowser,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('ကြော်ငြာ Browser မှာ ပြန်ဖွင့်မယ်'),
            ),
            const SizedBox(height: 10),
            Text(
              'ကြော်ငြာ မပေါ်ချင်ရင် Settings မှာ ကုတ် ထည့်ပါ (၃,၅၀၀ Ks/month)။',
              style: TextStyle(color: mutedColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
