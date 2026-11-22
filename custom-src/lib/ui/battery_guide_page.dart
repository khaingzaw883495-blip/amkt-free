import 'package:flutter/material.dart';

import '../services/system_helper.dart';

/// Battery Optimization Guide screen (v1.0.10): helps prevent Android
/// phones from killing AMKT VPN in the background.
class BatteryGuidePage extends StatefulWidget {
  const BatteryGuidePage({super.key});

  @override
  State<BatteryGuidePage> createState() => _BatteryGuidePageState();
}

class _BatteryGuidePageState extends State<BatteryGuidePage>
    with WidgetsBindingObserver {
  bool? _ignoring;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check();
    }
  }

  Future<void> _check() async {
    final ok = await SystemHelper.isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _ignoring = ok);
  }

  Future<void> _openSettings() async {
    await SystemHelper.requestIgnoreBatteryOptimizations();
    await Future.delayed(const Duration(milliseconds: 600));
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final ignoring = _ignoring == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Battery Optimization လမ်းညွှန်'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        ignoring
                            ? Icons.battery_charging_full
                            : Icons.battery_alert,
                        color: ignoring ? Colors.green : Colors.orange,
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          ignoring
                              ? 'Battery Optimization ပိတ်ပြီးသားပါ (ကောင်း)'
                              : 'Battery Optimization ဖွင့်ထားဆဲပါ',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    ignoring
                        ? 'ဖုန်း screen ပိတ်ထားချိန်မှာလည်း AMKT VPN ကို အလိုလို ပိတ်မပစ်တော့ပါဘူး။'
                        : 'ဖုန်း screen ပိတ်လိုက်ရင် VPN အလိုလို ပြုတ်သွားတတ်တာကို ကာကွယ်ဖို့ AMKT VPN ကို Battery Optimization ကနေ ဖယ်ထုတ်ထားသင့်ပါတယ်။',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _openSettings,
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(
                        ignoring
                            ? 'Battery Setting ပြန်စစ်မယ်'
                            : 'Battery Optimization ပိတ်မယ်',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'ဖုန်းအမျိုးအစားအလိုက် လမ်းညွှန်',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          _brandCard(
            'Xiaomi / Redmi / POCO (MIUI / HyperOS)',
            'Settings → Apps → Manage apps → AMKT VPN → Battery saver ကို "No restrictions" ရွေးပါ။ Autostart ကိုလည်း ဖွင့်ထားပါ။',
            muted,
          ),
          _brandCard(
            'Samsung (One UI)',
            'Settings → Apps → AMKT VPN → Battery → "Unrestricted" ကို ရွေးပါ။',
            muted,
          ),
          _brandCard(
            'OPPO / Realme / OnePlus',
            'Settings → Apps → App management → AMKT VPN → Battery usage → "Allow background activity" နဲ့ "Allow foreground activity" ဖွင့်ပါ။',
            muted,
          ),
          _brandCard(
            'Vivo / iQOO',
            'Settings → Battery → Background power consumption management → AMKT VPN ကို "Don\'t restrict background power usage" ရွေးပါ။',
            muted,
          ),
          _brandCard(
            'Huawei / Honor',
            'Settings → Battery → App launch → AMKT VPN ကို Manual ပြောင်းပြီး Auto-launch, Secondary launch, Run in background ၃ ခုလုံး ဖွင့်ပါ။',
            muted,
          ),
        ],
      ),
    );
  }

  Widget _brandCard(String title, String body, Color muted) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(body, style: TextStyle(color: muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
