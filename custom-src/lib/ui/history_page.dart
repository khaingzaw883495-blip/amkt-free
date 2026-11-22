import 'package:flutter/material.dart';

import '../services/app_store.dart';

/// Connection History screen (v1.0.10): lists past VPN sessions with
/// server, country, protocol, time, duration, and data used.
class HistoryPage extends StatefulWidget {
  final AppStore store;

  const HistoryPage({super.key, required this.store});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('မှတ်တမ်း ဖျက်မလား?'),
        content: const Text('ချိတ်ဆက်ခဲ့တဲ့ မှတ်တမ်းအားလုံးကို ဖျက်ပစ်ပါမယ်။'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('မဖျက်ဘူး'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('ဖျက်မယ်'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.clearConnectionHistory();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final entries = widget.store.connectionHistory;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ချိတ်ဆက်မှု မှတ်တမ်း'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'မှတ်တမ်းအားလုံး ဖျက်မယ်',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history, size: 48, color: muted),
                    const SizedBox(height: 12),
                    Text(
                      'ချိတ်ဆက်မှု မှတ်တမ်း မရှိသေးပါ',
                      style: TextStyle(color: muted, fontSize: 15),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final e = entries[index];
                return Card(
                  elevation: 0,
                  child: ListTile(
                    leading: Text(
                      e.countryFlag,
                      style: const TextStyle(fontSize: 24),
                    ),
                    title: Text(
                      '${e.serverName} (${e.countryName})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${_fmtDateTime(e.connectedAt)} • ${_fmtDuration(e.durationSeconds)} • ${_fmtBytes(e.dataBytes)}'
                      '${e.protocol.isNotEmpty ? ' • ${e.protocol}' : ''}',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _fmtDateTime(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$m-$day $hh:$mm';
  }

  String _fmtDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${s}s';
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}
