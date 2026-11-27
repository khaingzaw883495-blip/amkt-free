import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:installed_apps/installed_apps.dart';

import '../services/app_store.dart';
import '../services/per_app_vpn.dart';
import '../services/vpn_engine.dart';

/// Per-app VPN (split tunnel) — pick which apps use the VPN.
///
/// Ticked apps go through the VPN; unticked apps use the normal
/// internet. NOTHING ticked = every app uses the VPN, exactly as
/// before. The selection is saved on the phone and applied to the
/// sing-box tunnel (see PerAppVpnService for the mechanism).
class PerAppVpnPage extends StatefulWidget {
  const PerAppVpnPage({super.key});

  @override
  State<PerAppVpnPage> createState() => _PerAppVpnPageState();
}

class _PerAppVpnPageState extends State<PerAppVpnPage> {
  AppStore? _store;
  List<AppInfo> _apps = [];
  Set<String> _selected = {};
  String _query = '';
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  bool _includeSystemApps = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    final store = await AppStore.load();
    final apps = await PerAppVpnService.loadApps(
      includeSystemApps: _includeSystemApps,
    );
    // Heal drift: make sure sing-box's stored rules match the saved
    // selection (a failed write earlier leaves them out of sync).
    await PerAppVpnService.applyStoredSelection(store);
    if (!mounted) return;
    setState(() {
      _store = store;
      _apps = apps;
      _selected = store.perAppPackages;
      _loading = false;
      _loadFailed = apps.isEmpty;
    });
  }

  List<AppInfo> get _filtered {
    if (_query.isEmpty) return _apps;
    final q = _query.toLowerCase();
    return _apps
        .where(
          (a) =>
              a.name.toLowerCase().contains(q) ||
              a.packageName.toLowerCase().contains(q),
        )
        .toList();
  }

  Future<void> _toggle(String packageName, bool ticked) async {
    final store = _store;
    if (store == null || _saving) return;
    setState(() {
      _saving = true;
      if (ticked) {
        _selected = {..._selected, packageName};
      } else {
        _selected = _selected.where((p) => p != packageName).toSet();
      }
    });
    await PerAppVpnService.saveSelection(store, _selected);
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _selectAll(bool select) async {
    final store = _store;
    if (store == null || _saving) return;
    setState(() {
      _saving = true;
      _selected = select ? _apps.map((a) => a.packageName).toSet() : {};
    });
    await PerAppVpnService.saveSelection(store, _selected);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final connected = VpnEngine.instance.isConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('App ရွေးချယ် VPN')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.apps_outlined,
                      size: 44,
                      color: Colors.white54,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'App စာရင်း ဆွဲမရပါ — ဖုန်းမှာ app တွေ ရှာမတွေ့ဘူး။',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _load,
                      child: const Text('ပြန်စမ်းမည်'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    elevation: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selected.isEmpty
                                ? 'ဘာမှ မရွေးထားဘူး — app အားလုံး VPN သုံးနေပါတယ်။'
                                : 'App ${_selected.length} ခု ရွေးထားတယ် — အဲဒီ app တွေပဲ VPN သုံးမယ်၊ ကျန်တာ ရိုးရိုးအင်တာနက် သုံးမယ်။',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'အမှတ်ခြစ်ထားတဲ့ app တွေပဲ VPN ကနေ သွားမယ်။${connected ? ' ချိတ်ထားတုန်း ပြောင်းရင် tunnel ခန ပြန်စမယ်။' : ''}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('System apps ပါပြမယ်'),
                        value: _includeSystemApps,
                        onChanged: _saving
                            ? null
                            : (value) {
                                setState(() => _includeSystemApps = value);
                                _load();
                              },
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              decoration: const InputDecoration(
                                hintText: 'App ရှာမယ်…',
                                prefixIcon: Icon(Icons.search),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _saving ? null : () => _selectAll(true),
                            child: const Text('အားလုံး'),
                          ),
                          TextButton(
                            onPressed: _saving ? null : () => _selectAll(false),
                            child: const Text('ဖြုတ်မယ်'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _filtered.isEmpty
                      ? const Center(
                          child: Text(
                            'ရှာမတွေ့ပါ',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                          itemCount: _filtered.length,
                          itemBuilder: (context, i) {
                            final app = _filtered[i];
                            final ticked = _selected.contains(app.packageName);
                            return CheckboxListTile(
                              value: ticked,
                              onChanged: (v) =>
                                  _toggle(app.packageName, v ?? false),
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                app.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                app.packageName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.55),
                                ),
                              ),
                              secondary: _appIcon(app.icon),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _appIcon(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return const Icon(Icons.apps, color: Colors.white54);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(bytes, width: 36, height: 36),
    );
  }
}
