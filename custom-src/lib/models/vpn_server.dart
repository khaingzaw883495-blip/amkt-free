import 'dart:convert';

/// Protocols this app supports. VLESS / VMess / Trojan / Shadowsocks run
/// through the sing-box core.
enum VpnProtocol { vless, vmess, trojan, shadowsocks, openvpn, dnstt, slowdns }

extension VpnProtocolLabel on VpnProtocol {
  String get label => switch (this) {
        VpnProtocol.vless => 'VLESS',
        VpnProtocol.vmess => 'VMess',
        VpnProtocol.trojan => 'Trojan',
        VpnProtocol.shadowsocks => 'Shadowsocks',
        VpnProtocol.openvpn => 'OpenVPN',
        VpnProtocol.dnstt => 'DNSTT',
        VpnProtocol.slowdns => 'SlowDNS',
      };
}

/// One server, parsed from a share link (vless://, vmess://, trojan://,
/// ss://).
class VpnServer {
  final String id;
  final VpnProtocol protocol;
  final String name;
  final String address;
  final int port;
  final String? uuid; // vless / vmess
  final String? password; // trojan / shadowsocks / openvpn
  final String? username; // openvpn
  final String? method; // shadowsocks cipher
  final String? rawLink; // original share link (vless/vmess/trojan/ss)
  final String subscriptionId; // which subscription this came from
  // Manual tunnel / OpenVPN fields (added from Settings):
  final String? payload; // DNSTT/SlowDNS payload
  final String? proxyIp; // optional proxy IP
  final int? proxyPort; // optional proxy port
  final String? pubKey; // DNSTT server public key
  final String? ovpnConfig; // full .ovpn file content (OpenVPN)

  const VpnServer({
    required this.id,
    required this.protocol,
    required this.name,
    required this.address,
    required this.port,
    required this.subscriptionId,
    this.uuid,
    this.password,
    this.username,
    this.method,
    this.rawLink,
    this.payload,
    this.proxyIp,
    this.proxyPort,
    this.pubKey,
    this.ovpnConfig,
  });

  /// DNS-tunnel modes (DNSTT / SlowDNS) need a native tunnel client that
  /// is NOT in this build yet — the server is saved and listed, but
  /// connecting shows "coming soon" (see VpnEngine).
  ///
  /// v1.0.7 — OpenVPN is GONE too: the .ovpn import was removed, so no
  /// OpenVPN server can be created any more. An old saved OpenVPN
  /// server (if any) cannot connect either — it shows "coming soon".
  bool get isDnsTunnel =>
      protocol == VpnProtocol.dnstt || protocol == VpnProtocol.slowdns;

  bool get canConnect =>
      !isDnsTunnel && protocol != VpnProtocol.openvpn;

  /// Country of this server, detected from its name (remark) first, then
  /// its address/hostname — the free-list names are written by Amkt herself
  /// (e.g. "SG Fast VIP", "JP …", "US …"), so the name is the reliable
  /// signal. No network lookup is done. Returns a 2-letter ISO code, or
  /// '' when nothing matches.
  static const Map<String, List<String>> _countryWords = {
    'US': ['US', 'USA', 'AMERICA', 'UNITED STATES'],
    'SG': ['SG', 'SINGAPORE'],
    'JP': ['JP', 'JAPAN'],
    'TH': ['TH', 'THAILAND', 'THAI'],
    'MM': ['MM', 'MYANMAR', 'BURMA'],
    'KR': ['KR', 'KOREA'],
    'TW': ['TW', 'TAIWAN'],
    'HK': ['HK', 'HONG KONG', 'HONGKONG'],
    'VN': ['VN', 'VIETNAM'],
    'MY': ['MY', 'MALAYSIA'],
    'ID': ['ID', 'INDONESIA'],
    'PH': ['PH', 'PHILIPPINES'],
    'IN': ['IN', 'INDIA'],
    'DE': ['DE', 'GERMANY'],
    'NL': ['NL', 'NETHERLANDS', 'HOLLAND'],
    'GB': ['GB', 'UK', 'BRITAIN', 'ENGLAND'],
    'FR': ['FR', 'FRANCE'],
    'AU': ['AU', 'AUSTRALIA'],
    'CA': ['CA', 'CANADA'],
    'CN': ['CN', 'CHINA'],
    'RU': ['RU', 'RUSSIA'],
    'TR': ['TR', 'TURKEY', 'TURKIYE'],
    'AE': ['AE', 'UAE', 'DUBAI'],
    'SA': ['SA', 'SAUDI'],
  };

  String get countryCode {
    for (final source in [name, address]) {
      final code = _detectCountry(source);
      if (code.isNotEmpty) return code;
    }
    return '';
  }

  /// A word matches only with a word boundary around it (start/end, or a
  /// non-letter next to it) — so "SG2", "SG Fast" and "[SG]" match SG,
  /// while "USER" does not match US and "LOGIN" does not match IN.
  static String _detectCountry(String text) {
    final upper = text.toUpperCase();
    for (final entry in _countryWords.entries) {
      for (final word in entry.value) {
        final re = RegExp(
            '(^|[^A-Z0-9])${RegExp.escape(word)}(?=\$|[^A-Z])');
        if (re.hasMatch(upper)) return entry.key;
      }
    }
    return '';
  }

  /// Flag emoji for [countryCode] (regional indicators), or a globe when
  /// the country is unknown.
  String get countryFlag {
    final code = countryCode;
    if (code.isEmpty) return '🌐';
    return String.fromCharCodes(
        code.codeUnits.map((c) => 0x1F1E6 + c - 0x41));
  }

  /// Display name for [countryCode] ('USA', 'Singapore', ...).
  /// Unknown country → 'အခြား'. Used for the country-group headings —
  /// server names and IPs are never shown in the UI.
  static const Map<String, String> _countryNames = {
    'US': 'USA',
    'SG': 'Singapore',
    'JP': 'Japan',
    'TH': 'Thailand',
    'MM': 'Myanmar',
    'KR': 'South Korea',
    'TW': 'Taiwan',
    'HK': 'Hong Kong',
    'VN': 'Vietnam',
    'MY': 'Malaysia',
    'ID': 'Indonesia',
    'PH': 'Philippines',
    'IN': 'India',
    'DE': 'Germany',
    'NL': 'Netherlands',
    'GB': 'United Kingdom',
    'FR': 'France',
    'AU': 'Australia',
    'CA': 'Canada',
    'CN': 'China',
    'RU': 'Russia',
    'TR': 'Türkiye',
    'AE': 'UAE',
    'SA': 'Saudi Arabia',
  };

  String get countryName {
    final code = countryCode;
    if (code.isEmpty) return 'အခြား';
    return _countryNames[code] ?? code;
  }

  /// What to hand to the sing-box core.
  /// VLESS/VMess/Trojan/Shadowsocks: the original share link (the plugin
  /// parses it).
  String get connectInput => rawLink ?? '';

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocol': protocol.name,
        'name': name,
        'address': address,
        'port': port,
        'uuid': uuid,
        'password': password,
        'username': username,
        'method': method,
        'rawLink': rawLink,
        'subscriptionId': subscriptionId,
        'payload': payload,
        'proxyIp': proxyIp,
        'proxyPort': proxyPort,
        'pubKey': pubKey,
        'ovpnConfig': ovpnConfig,
      };

  factory VpnServer.fromJson(Map<String, dynamic> j) => VpnServer(
        id: j['id'] as String,
        protocol: VpnProtocol.values.byName(j['protocol'] as String),
        name: j['name'] as String,
        address: j['address'] as String,
        port: (j['port'] as num).toInt(),
        uuid: j['uuid'] as String?,
        password: j['password'] as String?,
        username: j['username'] as String?,
        method: j['method'] as String?,
        rawLink: j['rawLink'] as String?,
        subscriptionId: j['subscriptionId'] as String,
        payload: j['payload'] as String?,
        proxyIp: j['proxyIp'] as String?,
        proxyPort: (j['proxyPort'] as num?)?.toInt(),
        pubKey: j['pubKey'] as String?,
        ovpnConfig: j['ovpnConfig'] as String?,
      );

  /// A server added by the user (share link / .ovpn import)
  /// (DNSTT / SlowDNS tabs).
  factory VpnServer.manualTunnel({
    required VpnProtocol protocol, // dnstt / slowdns
    required String name,
    required String address,
    required int port,
    String? username,
    String? password,
    String? payload,
    String? proxyIp,
    int? proxyPort,
    String? pubKey,
  }) =>
      VpnServer(
        id: _idFor(protocol, address, port,
            '$username:$password:${DateTime.now().millisecondsSinceEpoch}'),
        protocol: protocol,
        name: name,
        address: address,
        port: port,
        username: username,
        password: password,
        payload: payload,
        proxyIp: proxyIp,
        proxyPort: proxyPort,
        pubKey: pubKey,
        subscriptionId: 'manual',
      );

  /// A server imported from a .ovpn file. [ovpnConfig] is the whole file
  /// content; remote host/port are read from it for display.
  factory VpnServer.openvpn({
    required String name,
    required String ovpnConfig,
    String? username,
    String? password,
  }) {
    var host = '';
    var port = 1194;
    for (final line in ovpnConfig.split('\n')) {
      final t = line.trim();
      if (t.startsWith('remote ')) {
        final parts = t.split(RegExp(r'\s+'));
        if (parts.length >= 2) host = parts[1];
        if (parts.length >= 3) port = int.tryParse(parts[2]) ?? 1194;
        break;
      }
    }
    return VpnServer(
      id: _idFor(VpnProtocol.openvpn, host, port,
          '${ovpnConfig.hashCode}:${DateTime.now().millisecondsSinceEpoch}'),
      protocol: VpnProtocol.openvpn,
      name: name,
      address: host,
      port: port,
      username: username,
      password: password,
      ovpnConfig: ovpnConfig,
      subscriptionId: 'manual',
    );
  }

  static String _idFor(VpnProtocol p, String address, int port, String secret) =>
      '${p.name}-${address.hashCode.abs()}-$port-${secret.hashCode.abs()}';

  // ---------------------------------------------------------------- parsing

  static String _decodeBase64Loose(String input) {
    var s = input.trim().replaceAll('\n', '').replaceAll('\r', '');
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    final pad = s.length % 4;
    if (pad > 0) s += '=' * (4 - pad);
    try {
      return utf8.decode(base64.decode(s));
    } catch (_) {
      return utf8.decode(base64Url.decode(s));
    }
  }

  static bool _looksLikeBase64(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length % 4 == 1) return false;
    return RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(t);
  }

  /// Parse one share link. Returns null when the line is not a known link.
  static VpnServer? parseShareLink(String link, {required String subscriptionId}) {
    final line = link.trim();
    if (line.isEmpty || line.startsWith('#')) return null;
    try {
      if (line.startsWith('vless://')) return _parseVless(line, subscriptionId);
      if (line.startsWith('vmess://')) return _parseVmess(line, subscriptionId);
      if (line.startsWith('trojan://')) return _parseTrojan(line, subscriptionId);
      if (line.startsWith('ss://')) return _parseSs(line, subscriptionId);
    } catch (_) {
      return null;
    }
    return null;
  }

  static VpnServer _parseVless(String line, String subId) {
    final uri = Uri.parse(line);
    final uuid = uri.userInfo;
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${uri.host}:${uri.port}';
    return VpnServer(
      id: _idFor(VpnProtocol.vless, uri.host, uri.port, uuid),
      protocol: VpnProtocol.vless,
      name: name,
      address: uri.host,
      port: uri.port,
      uuid: uuid,
      rawLink: line,
      subscriptionId: subId,
    );
  }

  static VpnServer _parseVmess(String line, String subId) {
    final j = jsonDecode(_decodeBase64Loose(line.substring('vmess://'.length)))
        as Map<String, dynamic>;
    final address = (j['add'] ?? '') as String;
    final port = int.tryParse('${j['port']}') ?? 0;
    final uuid = (j['id'] ?? '') as String;
    final name = (j['ps'] ?? '').toString().isNotEmpty
        ? (j['ps'] as String)
        : '$address:$port';
    return VpnServer(
      id: _idFor(VpnProtocol.vmess, address, port, uuid),
      protocol: VpnProtocol.vmess,
      name: name,
      address: address,
      port: port,
      uuid: uuid,
      rawLink: line,
      subscriptionId: subId,
    );
  }

  static VpnServer _parseTrojan(String line, String subId) {
    final uri = Uri.parse(line);
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${uri.host}:${uri.port}';
    return VpnServer(
      id: _idFor(VpnProtocol.trojan, uri.host, uri.port, uri.userInfo),
      protocol: VpnProtocol.trojan,
      name: name,
      address: uri.host,
      port: uri.port,
      password: Uri.decodeComponent(uri.userInfo),
      rawLink: line,
      subscriptionId: subId,
    );
  }

  static VpnServer _parseSs(String line, String subId) {
    var rest = line.substring('ss://'.length);
    var name = '';
    final hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      name = Uri.decodeComponent(rest.substring(hashIdx + 1));
      rest = rest.substring(0, hashIdx);
    }
    String method, password, host;
    int port;
    if (rest.contains('@')) {
      // ss://base64(method:password)@host:port
      final atIdx = rest.lastIndexOf('@');
      final userPart = _decodeBase64Loose(rest.substring(0, atIdx));
      final hostPart = rest.substring(atIdx + 1);
      final colonIdx = userPart.indexOf(':');
      method = userPart.substring(0, colonIdx);
      password = userPart.substring(colonIdx + 1);
      final hp = hostPart.split(':');
      host = hp[0];
      port = int.tryParse(hp.length > 1 ? hp[1] : '') ?? 0;
    } else {
      // ss://base64(method:password@host:port)
      final decoded = _decodeBase64Loose(rest);
      final atIdx = decoded.lastIndexOf('@');
      final userPart = decoded.substring(0, atIdx);
      final hostPart = decoded.substring(atIdx + 1);
      final colonIdx = userPart.indexOf(':');
      method = userPart.substring(0, colonIdx);
      password = userPart.substring(colonIdx + 1);
      final hp = hostPart.split(':');
      host = hp[0];
      port = int.tryParse(hp.length > 1 ? hp[1] : '') ?? 0;
    }
    if (name.isEmpty) name = '$host:$port';
    return VpnServer(
      id: _idFor(VpnProtocol.shadowsocks, host, port, password),
      protocol: VpnProtocol.shadowsocks,
      name: name,
      address: host,
      port: port,
      password: password,
      method: method,
      rawLink: line,
      subscriptionId: subId,
    );
  }

  /// Parse a whole subscription file: plain lines of links, or the same
  /// list base64-encoded. Also accepts a JSON array of links.
  static List<VpnServer> parseSubscriptionBody(String body,
      {required String subscriptionId}) {
    var text = body.trim();
    if (text.isEmpty) return [];
    if (text.startsWith('[')) {
      try {
        final arr = jsonDecode(text) as List;
        return arr
            .map((e) => parseShareLink(e.toString(), subscriptionId: subscriptionId))
            .whereType<VpnServer>()
            .toList();
      } catch (_) {
        // fall through to line parsing
      }
    }
    if (_looksLikeBase64(text) && !text.contains('://')) {
      try {
        final decoded = _decodeBase64Loose(text);
        if (decoded.contains('://')) text = decoded;
      } catch (_) {
        // keep original text
      }
    }
    final out = <VpnServer>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final s = parseShareLink(line, subscriptionId: subscriptionId);
      if (s != null) out.add(s);
    }
    return out;
  }
}
