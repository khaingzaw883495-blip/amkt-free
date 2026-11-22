import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/hotspot_proxy.dart';
import '../services/system_helper.dart';
import '../services/vpn_engine.dart';

/// Wi-Fi Hotspot VPN Sharing screen (v1.0.10).
class HotspotPage extends StatefulWidget {
  const HotspotPage({super.key});

  @override
  State<HotspotPage> createState() => _HotspotPageState();
}

class _HotspotPageState extends State<HotspotPage> {
  final _proxy = HotspotProxyService.instance;
  final _portCtrl = TextEditingController(text: '8080');
  bool _busy = false;
  String? _ip;

  @override
  void initState() {
    super.initState();
    _portCtrl.text = _proxy.port.toString();
    _refreshIp();
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshIp() async {
    final ip = await _proxy.detectLocalIp();
    if (mounted) setState(() => _ip = ip);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggle(bool enable) async {
    if (_busy) return;
    setState(() => _busy = true);
    if (enable) {
      final parsed = int.tryParse(_portCtrl.text.trim()) ?? 8080;
      final port = (parsed >= 1024 && parsed <= 65535) ? parsed : 8080;
      final ok = await _proxy.start(port: port);
      if (mounted) {
        setState(() {
          _busy = false;
          _ip = _proxy.localIp;
        });
        _snack(ok
            ? 'Hotspot Proxy ဖွင့်ပြီးပြီ (Port $port)'
            : 'ဖွင့်မရပါ: ${_proxy.lastError ?? 'Port အသုံးပြုနေပါတယ်'}');
      }
    } else {
      await _proxy.stop();
      if (mounted) {
        setState(() => _busy = false);
        _snack('Hotspot Proxy ပိတ်ပြီးပြီ');
      }
    }
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    _snack('$label ကူးယူပြီးပြီ ($value)');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final running = _proxy.isRunning;
    final vpnConnected = VpnEngine.instance.isConnected;
    final displayIp = _ip ?? _proxy.localIp ?? '192.168.43.1';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hotspot VPN မျှသုံးရန်'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!vpnConnected)
            Card(
              elevation: 0,
              color: Colors.amber.withValues(alpha: isDark ? 0.16 : 0.14),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Hotspot မျှသုံးဖို့ VPN ကို အရင် Connect လုပ်ထားပါ။',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            child: SwitchListTile(
              secondary: Icon(
                Icons.wifi_tethering,
                color: running
                    ? Colors.green
                    : Theme.of(context).colorScheme.primary,
              ),
              title: const Text(
                'Hotspot Proxy ဖွင့်မယ်',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                running
                    ? 'ဖွင့်ထားတယ် — အခြားဖုန်း/ကွန်ပျူတာကနေ Proxy ချိတ်သုံးနိုင်ပါပြီ'
                    : 'VPN လိုင်းကို Wi-Fi Hotspot ကနေ မျှပေးရန် ဖွင့်ပါ',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              value: running,
              onChanged: _busy ? null : _toggle,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Proxy အချက်အလက်',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: 'IP ပြန်စစ်မယ်',
                        onPressed: _refreshIp,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Proxy Host (IP)'),
                    subtitle: Text(
                      displayIp,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copy('IP', displayIp),
                    ),
                  ),
                  const Divider(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portCtrl,
                          enabled: !running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Proxy Port',
                            hintText: '8080',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => _copy('Port', _portCtrl.text.trim()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => SystemHelper.openHotspotSettings(),
                      icon: const Icon(Icons.settings_input_antenna, size: 18),
                      label: const Text('ဖုန်း Hotspot Setting ဖွင့်မယ်'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'အသုံးပြုပုံ အဆင့်ဆင့်',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 10),
                  _step(
                      '၁။', 'ဒီဖုန်းမှာ AMKT VPN ချိတ်ပြီး Wi-Fi Hotspot ဖွင့်ပါ။', muted),
                  _step('၂။', 'အပေါ်က "Hotspot Proxy ဖွင့်မယ်" ခလုတ်ကို ဖွင့်ပါ။', muted),
                  _step(
                      '၃။',
                      'အခြားဖုန်း/Laptop ကနေ ဒီဖုန်းရဲ့ Hotspot Wi-Fi ကို ချိတ်ပါ။',
                      muted),
                  _step(
                      '၄။',
                      'အဲဒီဖုန်းရဲ့ Wi-Fi Setting → Proxy → Manual ရွေးပြီး Host နေရာမှာ $displayIp နဲ့ Port နေရာမှာ ${_portCtrl.text.trim()} ထည့်ပြီး Save လုပ်ပါ။',
                      muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String num, String text, Color muted) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(num, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: muted, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
