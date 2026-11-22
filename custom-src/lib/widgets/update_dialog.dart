import 'package:flutter/material.dart';

import '../config.dart';
import '../services/app_update.dart';

/// In-app update dialog — Amkt's own look (dark card, purple/cyan,
/// rounded corners, like the ad-gate sheet). Shows the new version,
/// the notes, and downloads the APK inside the app with progress,
/// then opens the Android installer.
class UpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;

  const UpdateDialog({super.key, required this.info});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

enum _DlState { idle, needPermission, downloading, error }

class _UpdateDialogState extends State<UpdateDialog> {
  _DlState _state = _DlState.idle;
  double? _progress;
  String _progressText = '';
  String? _error;

  Future<void> _startUpdate() async {
    final can = await AppUpdateService.canInstall();
    if (!mounted) return;
    if (!can) {
      setState(() => _state = _DlState.needPermission);
      return;
    }
    await _download();
  }

  Future<void> _download() async {
    setState(() {
      _state = _DlState.downloading;
      _progress = 0;
      _progressText = 'Download စတင်နေသည်…';
      _error = null;
    });
    // v1.0.7 — download and install failures are reported separately:
    // the old code labelled every failure "Download မရပါ", even when
    // the download had succeeded and the INSTALL step failed (the
    // FileProvider code_cache bug, now fixed in app_update.dart).
    late final String path;
    try {
      path =
          await AppUpdateService.downloadApk(widget.info.apkUrl, (received, total) {
        if (!mounted) return;
        setState(() {
          _progress = total != null && total > 0 ? received / total : null;
          final mb = (received / 1048576).toStringAsFixed(1);
          _progressText = total != null && total > 0
              ? 'Download ဆွဲနေသည် ${(received / total * 100).round()}% ($mb MB)'
              : 'Download ဆွဲနေသည် ($mb MB)';
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _DlState.error;
        _error =
            'Download မရပါ: ${e.toString().replaceFirst('Exception: ', '')}';
      });
      return;
    }
    if (!mounted) return;
    try {
      await AppUpdateService.installApk(path);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _DlState.error;
        _error =
            'Install မရပါ: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final downloading = _state == _DlState.downloading;
    return PopScope(
      canPop: !downloading,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1E1A3A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Row(
          children: [
            Icon(Icons.system_update, color: Color(0xFF22D3EE)),
            SizedBox(width: 8),
            Text('App အသစ် ရှိပါပြီ'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'v${AmktConfig.currentVersion}  →  v${info.version}',
                style: const TextStyle(
                  color: Color(0xFF22D3EE),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(info.notes,
                    style: const TextStyle(color: Colors.white70)),
              ],
              if (_state == _DlState.needPermission) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'APK သွင်းခွင့် လိုပါတယ် — ဆက်တင် မှာ "Allow from this source" ကို ဖွင့်ပေးပါ။ ပြီးရင် Update ကို ထပ်နှိပ်ပါ။',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              ],
              if (downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF22D3EE),
                ),
                const SizedBox(height: 8),
                Text(_progressText,
                    style: const TextStyle(color: Colors.white70)),
              ],
              if (_state == _DlState.error && _error != null) ...[
                const SizedBox(height: 14),
                Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
        actions: [
          if (!downloading)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('နောက်မှ'),
            ),
          if (_state == _DlState.needPermission)
            ElevatedButton(
              onPressed: () => AppUpdateService.openInstallSettings(),
              child: const Text('ဆက်တင် ဖွင့်ရန်'),
            ),
          if (_state == _DlState.idle || _state == _DlState.error)
            ElevatedButton(
              onPressed: _startUpdate,
              child: Text(_state == _DlState.error ? 'ထပ်လုပ်မည်' : 'Update လုပ်မည်'),
            ),
          if (_state == _DlState.needPermission)
            ElevatedButton(
              onPressed: _startUpdate,
              child: const Text('Update လုပ်မည်'),
            ),
        ],
      ),
    );
  }
}
