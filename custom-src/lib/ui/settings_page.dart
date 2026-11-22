import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/vpn_server.dart';
import '../services/app_store.dart';
import '../services/buyer_servers.dart';
import '../services/fcm_service.dart';
import '../services/redeem_code.dart';
import '../services/subscription_service.dart';
import '../services/theme_mode.dart';
import '../services/vpn_engine.dart';
import 'battery_guide_page.dart';
import 'history_page.dart';
import 'hotspot_page.dart';
import 'per_app_vpn_page.dart';

/// Settings tab (v1.0.10): VIP/No-Ads code, manual key & subscription entry,
/// Theme, Total Data Usage + Reset, Hotspot Share, Connection History,
/// Battery Optimization guide, Kill Switch, and Per-App VPN.
class SettingsTab extends StatefulWidget {
  final AppStore store;
  final VoidCallback? onNoAdsChanged;
  final VoidCallback? onDataUsageReset;

  const SettingsTab({
    super.key,
    required this.store,
    this.onNoAdsChanged,
    this.onDataUsageReset,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  AppStore get _store => widget.store;

  final _codeCtrl = TextEditingController();
  bool _codeBusy = false;

  final _keyCtrl = TextEditingController();
  bool _keyBusy = false;
  final _subCtrl = TextEditingController();
  bool _subBusy = false;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _keyCtrl.dispose();
    _subCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addKey() async {
    final link = _keyCtrl.text.trim();
    if (link.isEmpty || _keyBusy) return;
    setState(() => _keyBusy = true);
    try {
      final server = VpnServer.parseShareLink(link,
          subscriptionId: AppStore.manualSubId);
      if (server == null) throw const FormatException('not a share link');
      await _store.addManualServer(server);
      _keyCtrl.clear();
      if (mounted) {
        setState(() {});
        _snack('Key ထည့်ပြီးပြီ — VPN စာမျက်နှာက ဆာဗာရွေးတဲ့နေရာမှာ ကြည့်ပါ');
      }
    } catch (e) {
      if (mounted) {
        _snack('Key မှားနေပါတယ် — vless/vmess/trojan/ss link ထည့်ပါ');
      }
    } finally {
      if (mounted) setState(() => _keyBusy = false);
    }
  }

  Future<void> _addSubscription() async {
    final url = _subCtrl.text.trim();
    if (url.isEmpty || _subBusy) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      _snack('Subscription link မှားနေပါတယ် — http(s) link ထည့်ပါ');
      return;
    }
    setState(() => _subBusy = true);
    try {
      final id =
          'sub-${DateTime.now().millisecondsSinceEpoch}-${url.hashCode.abs()}';
      final fetch =
          await SubscriptionService.fetchWithInfo(url, subscriptionId: id);
      if (fetch.servers.isEmpty) {
        if (mounted) _snack('Server မတွေ့ပါ — link မှန်မမှန် စစ်ပါ');
        return;
      }
      final isPaid = AppStore.isOwnSubscriptionUrl(url);
      await _store.saveServers(id, fetch.servers);
      await _store.saveUserInfo(id, fetch.userinfo);
      await _store.addSubscription(url, isPaid: isPaid, id: id);
      _subCtrl.clear();
      if (mounted) {
        widget.onNoAdsChanged?.call();
        setState(() {});
        _snack(isPaid
            ? 'ကိုယ့် subscription ထည့်ပြီးပြီ — ကြော်ငြာ မပေါ်တော့ဘူး'
            : 'Subscription ထည့်ပြီးပြီ — ${fetch.servers.length} servers (free tier, ကြော်ငြာ ပေါ်မယ်)');
      }
    } catch (e) {
      if (mounted) _snack('Subscription ဆွဲမရပါ — link / အင်တာနက် စစ်ပါ');
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  Future<void> _setTheme(String mode) async {
    await _store.setThemeMode(mode);
    appThemeMode.value = themeModeFromString(mode);
    if (mounted) setState(() {});
  }

  Future<void> _redeemCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty || _codeBusy) return;
    setState(() => _codeBusy = true);
    final result = await NoAdsCodeService.redeemCode(_store, code);
    if (!mounted) return;
    setState(() => _codeBusy = false);
    if (result.valid) {
      await BuyerServersService.refreshBuyerServers(_store);
      await FcmService.syncTierTopic(isPaid: _store.hasPaidAccess);
      final exp = result.expiresAt;
      final expText = exp == null
          ? ''
          : ' — သက်တမ်း: ${exp.year}-${exp.month.toString().padLeft(2, '0')}-${exp.day.toString().padLeft(2, '0')}';
      _snack('ကုတ် မှန်ပါတယ် — ကြော်ငြာ မပေါ်တော့ဘူး$expText');
      _codeCtrl.clear();
      widget.onNoAdsChanged?.call();
      setState(() {});
    } else {
      _snack(result.message);
    }
  }

  Future<void> _renewCode() async {
    await launchUrl(
      Uri.parse('https://t.me/mmoutlinekey_bot'),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
  }

  Future<void> _confirmResetDataUsage() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ဒေတာ သုံးစွဲမှု Reset လုပ်မလား?'),
        content: const Text('စုစုပေါင်း ဒေတာသုံးစွဲမှု မှတ်တမ်းကို 0 ပြန်ချပါမယ်။'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('မလုပ်ဘူး'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _store.resetTotalDataBytes();
      widget.onDataUsageReset?.call();
      if (mounted) {
        setState(() {});
        _snack('ဒေတာ သုံးစွဲမှု Reset လုပ်ပြီးပြီ');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.white70 : const Color(0xFF475569);
    final faint = isDark ? Colors.white54 : const Color(0xFF64748B);
    final linkColor =
        isDark ? const Color(0xFF22D3EE) : const Color(0xFF0284C7);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Settings',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        const SizedBox(height: 16),
        Text(
          'Telegram bot ကနေ ဝယ်ထားတဲ့ ကုတ် (AMKT-XXXX-XXXX) ထည့်ပါ — ကြော်ငြာ မပေါ်တော့ဘူး၊ ၇ စက္ကန့်လည်း စောင့်စရာ မလိုတော့ဘူး။ ကုတ်က ဖုန်းတစ်လုံးထဲနဲ့ဘဲ အသုံးပြုလို့ရပါတယ်။',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 8),
        if (store.hasNoAdsAccess) ...[
          Card(
            elevation: 0,
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text('သက်တမ်း: ${_fmtDate(store.noAdsExpiresAt)}'),
              trailing: TextButton(
                onPressed: _renewCode,
                child: const Text('သက်တမ်းတိုးတာ'),
              ),
            ),
          ),
        ] else ...[
          if (store.noAdsCode != null)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'ကုတ် သက်တမ်း ကုန်နေပါပြီ — ကုတ်အသစ် ထည့်ပါ။',
                style: TextStyle(color: Colors.orange),
              ),
            ),
          TextField(
            controller: _codeCtrl,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'ကုတ်',
              hintText: 'AMKT-XXXX-XXXX',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _codeBusy ? null : _redeemCode,
            child: Text(_codeBusy ? 'စစ်နေတယ်…' : 'ကုတ် ထည့်မည်'),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'သားလေးအတွက် မုန့်ဖိုး — တစ်လ ၃,၅၀၀ ကျပ်',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 4),
        Text(
          'VIP Server',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Wrap(
          children: [
            Text('Telegram ', style: TextStyle(color: muted)),
            GestureDetector(
              onTap: () => launchUrl(
                Uri.parse('https://t.me/mmoutlinekey_bot'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(
                '@mmoutlinekey_bot',
                style: TextStyle(
                  color: linkColor,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            Text(' မှာ ဝယ်လို့ရတယ်', style: TextStyle(color: muted)),
          ],
        ),
        const SizedBox(height: 24),
        // ---- Tools & Records (v1.0.10) ----
        const Text('အသုံးဝင် ကိရိယာများ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        Card(
          elevation: 0,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.data_usage),
                title: const Text('ဒေတာ သုံးစွဲမှု စုစုပေါင်း'),
                subtitle: Text(
                  _fmtBytes(store.totalDataBytes),
                  style: TextStyle(color: muted, fontSize: 13),
                ),
                trailing: TextButton(
                  onPressed: _confirmResetDataUsage,
                  child: const Text('Reset'),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: const Text('Hotspot VPN မျှသုံးရန်'),
                subtitle: Text(
                  'VPN ကို Wi-Fi Hotspot ကနေ အခြားစက်များသို့ မျှပေးမယ်',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HotspotPage()),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('ချိတ်ဆက်မှု မှတ်တမ်း'),
                subtitle: Text(
                  'ချိတ်ဆက်ခဲ့တဲ့ ဆာဗာနဲ့ အချိန် မှတ်တမ်းများ (${store.connectionHistory.length})',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => HistoryPage(store: store)),
                  );
                  if (mounted) setState(() {});
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.battery_saver),
                title: const Text('Battery Optimization လမ်းညွှန်'),
                subtitle: Text(
                  'Screen ပိတ်ချိန် VPN မပြုတ်အောင် ချိန်ညှိနည်း',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const BatteryGuidePage()),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // ---- manual V2Ray key entry ----
        const Text('vless vmess trojan ss link ထည့်ရန်',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        TextField(
          controller: _keyCtrl,
          decoration: const InputDecoration(
            labelText: 'Key link',
            hintText: 'vless://…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _keyBusy ? null : _addKey,
          child: Text(_keyBusy ? 'ထည့်နေတယ်…' : 'Key ထည့်မည်'),
        ),
        ..._manualServerTiles(store, muted),
        const SizedBox(height: 24),
        // ---- subscription link import ----
        const Text('Subscription link ထည့်ရန်',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        TextField(
          controller: _subCtrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Subscription link',
            hintText: 'https://…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _subBusy ? null : _addSubscription,
          child: Text(_subBusy ? 'ဆွဲနေတယ်…' : 'Subscription ထည့်မည်'),
        ),
        ..._subscriptionTiles(store, muted),
        const SizedBox(height: 24),
        // ---- theme selector ----
        const Text('Theme',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        Card(
          elevation: 0,
          child: RadioGroup<String>(
            groupValue: store.themeMode,
            onChanged: (v) => v != null ? _setTheme(v) : null,
            child: const Column(
              children: [
                RadioListTile<String>(
                  title: Text('အလင်း — အပြာနု (Light)'),
                  value: 'light',
                ),
                RadioListTile<String>(
                  title: Text('အမှောင် (Dark)'),
                  value: 'dark',
                ),
                RadioListTile<String>(
                  title: Text('စစ်စတန် (System)'),
                  value: 'system',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Kill Switch',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        Card(
          elevation: 0,
          child: SwitchListTile(
            title: const Text('VPN ပြုတ်ရင် အင်တာနက် ပိတ်ထားမယ်'),
            subtitle: Text(
              'VPN ချိတ်မထားချိန် အင်တာနက် မသုံးရအောင် ပိတ်တာ — IP မပေါက်စေဖို့။ အပြည့်အဝ အလုပ်လုပ်ဖို့ Android system setting ထဲမှာ AMKT VPN အတွက် "Block connections without VPN" ဖွင့်ရမယ်။',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            value: store.killSwitch,
            onChanged: (value) async {
              final messenger = ScaffoldMessenger.of(context);
              await store.setKillSwitch(value);
              await VpnEngine.instance.applyKillSwitch(value);
              if (!mounted) return;
              setState(() {});
              if (value) {
                messenger.showSnackBar(
                  SnackBar(
                    content: const Text(
                        'Kill switch ဖွင့်ပြီးပြီ — အပြည့်အဝ အလုပ်လုပ်ဖို့ system setting မှာ "Block connections without VPN" ဖွင့်ပါ။'),
                    action: SnackBarAction(
                      label: 'System setting ဖွင့်မယ်',
                      onPressed: () =>
                          VpnEngine.instance.openSystemVpnSettings(),
                    ),
                    duration: const Duration(seconds: 8),
                  ),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 24),
        const Text('App ရွေးချယ် VPN',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        Card(
          elevation: 0,
          child: ListTile(
            leading: const Icon(Icons.apps),
            title: const Text('ဘယ် app တွေ VPN သုံးမလဲ'),
            subtitle: Text(
              store.perAppPackages.isEmpty
                  ? 'မရွေးထားဘူး — app အားလုံး VPN သုံးနေပါတယ်။'
                  : 'App ${store.perAppPackages.length} ခု ရွေးထားတယ် — အဲဒီ app တွေပဲ VPN သုံးမယ်။',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PerAppVpnPage()),
              );
              if (mounted) setState(() {});
            },
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => launchUrl(Uri.parse(AmktConfig.telegramUrl),
              mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.send),
          label: const Text('Telegram — @amktvpn'),
        ),
        const SizedBox(height: 24),
        Text(
          'AMKT VPN ${AmktConfig.currentVersion}\nCore: sing-box 1.14.4 (VLESS / VMess / Trojan / Shadowsocks)',
          textAlign: TextAlign.center,
          style: TextStyle(color: faint, fontSize: 12),
        ),
      ],
    );
  }

  List<Widget> _manualServerTiles(AppStore store, Color muted) {
    final manual = store.serversCache[AppStore.manualSubId] ?? [];
    if (manual.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      ...manual.map((s) => Card(
            elevation: 0,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.key, size: 20),
              title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${s.protocol.label} • ${s.countryName}',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await store.removeManualServer(s.id);
                  if (mounted) setState(() {});
                },
              ),
            ),
          )),
    ];
  }

  List<Widget> _subscriptionTiles(AppStore store, Color muted) {
    final subs = store.subscriptions
        .where((s) => s.id != AppStore.freeSubId)
        .toList();
    if (subs.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      ...subs.map((sub) {
        final count = (store.serversCache[sub.id] ?? []).length;
        final own = AppStore.isOwnSubscriptionUrl(sub.url);
        final info = store.getUserInfo(sub.id);
        final infoLine =
            (info != null && info.displayLine.isNotEmpty) ? '\n${info.displayLine}' : '';
        return Card(
          elevation: 0,
          child: ListTile(
            dense: true,
            leading: Icon(
              own ? Icons.star : Icons.link,
              size: 20,
              color: own ? Colors.amber : null,
            ),
            title: Text(sub.label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '$count servers${own ? ' • ကိုယ့် subscription — ကြော်ငြာ မပေါ်ဘူး' : ''}$infoLine',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await store.removeSubscription(sub.id);
                if (mounted) setState(() {});
              },
            ),
          ),
        );
      }),
    ];
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
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
