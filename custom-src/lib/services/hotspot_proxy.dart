import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local HTTP/HTTPS CONNECT proxy server for sharing the phone's VPN
/// connection over Wi-Fi Hotspot (v1.0.10).
///
/// How it works on non-root Android:
/// 1. User connects AMKT VPN and turns on their phone's Wi-Fi Hotspot.
/// 2. User turns on Hotspot Share here (listens on 0.0.0.0:8080).
/// 3. On the other phone/laptop connected to the hotspot, user sets Manual
///    HTTP Proxy to this phone's Hotspot IP (e.g. 192.168.43.1) and Port 8080.
/// 4. If sing-box has a local loopback proxy port open (2080 / 10808 / 10809 /
///    7890), incoming connections are chained through it automatically;
///    otherwise connections are relayed directly.
class HotspotProxyService {
  HotspotProxyService._();
  static final HotspotProxyService instance = HotspotProxyService._();

  ServerSocket? _server;
  int _port = 8080;
  String? _localIp;
  int? _upstreamProxyPort;
  String? _lastError;

  bool get isRunning => _server != null;
  int get port => _port;
  String? get localIp => _localIp;
  int? get upstreamProxyPort => _upstreamProxyPort;
  String? get lastError => _lastError;

  static const _candidateSingBoxPorts = [2080, 10808, 10809, 7890];

  /// Detects the phone's most likely Wi-Fi Hotspot / LAN IPv4 address.
  Future<String?> detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      String? fallback;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final ip = addr.address;
          // Prioritize Android hotspot interfaces (ap0, swlan, wlan, rndis)
          if (name.contains('ap') ||
              name.contains('swlan') ||
              name.contains('rndis') ||
              ip.startsWith('192.168.43.') ||
              ip.startsWith('192.168.42.') ||
              ip.startsWith('192.168.137.')) {
            _localIp = ip;
            return ip;
          }
          if (name.contains('wlan') || ip.startsWith('192.168.')) {
            fallback ??= ip;
          } else {
            fallback ??= ip;
          }
        }
      }
      _localIp = fallback;
      return fallback;
    } catch (_) {
      return _localIp;
    }
  }

  Future<int?> _detectUpstreamSingBoxPort() async {
    for (final p in _candidateSingBoxPorts) {
      try {
        final s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          p,
          timeout: const Duration(milliseconds: 250),
        );
        s.destroy();
        return p;
      } catch (_) {}
    }
    return null;
  }

  /// Starts the local HTTP/CONNECT proxy server on [port].
  Future<bool> start({int port = 8080}) async {
    await stop();
    _port = port;
    _lastError = null;
    try {
      await detectLocalIp();
      _upstreamProxyPort = await _detectUpstreamSingBoxPort();
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        shared: true,
      );
      _server!.listen(
        _handleClient,
        onError: (_) {},
        cancelOnError: false,
      );
      return true;
    } catch (e) {
      _lastError = e.toString();
      _server = null;
      return false;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _upstreamProxyPort = null;
    if (s != null) {
      await s.close().catchError((_) {});
    }
  }

  Future<void> _handleClient(Socket client) async {
    Socket? remote;
    try {
      final headerBytes = <int>[];
      final completer = Completer<void>();
      late StreamSubscription<List<int>> sub;
      final remainingChunks = <List<int>>[];

      sub = client.listen(
        (chunk) {
          if (!completer.isCompleted) {
            headerBytes.addAll(chunk);
            final marker = _findHeaderEnd(headerBytes);
            if (marker != -1) {
              if (marker < headerBytes.length) {
                remainingChunks.add(headerBytes.sublist(marker));
                headerBytes.removeRange(marker, headerBytes.length);
              }
              sub.pause();
              completer.complete();
            } else if (headerBytes.length > 32768) {
              sub.cancel();
              completer.completeError('Header too large');
            }
          }
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.completeError('EOF');
        },
      );

      await completer.future.timeout(const Duration(seconds: 10));
      final headerStr = utf8.decode(headerBytes, allowMalformed: true);
      final firstLineEnd = headerStr.indexOf('\r\n');
      if (firstLineEnd <= 0) {
        client.destroy();
        return;
      }
      final requestLine = headerStr.substring(0, firstLineEnd);
      final parts = requestLine.split(' ');
      if (parts.length < 3) {
        client.destroy();
        return;
      }
      final method = parts[0].toUpperCase();
      final target = parts[1];

      // If sing-box local HTTP/mixed proxy is listening, forward directly to it.
      final upstreamPort = _upstreamProxyPort;
      if (upstreamPort != null) {
        remote = await Socket.connect(
          InternetAddress.loopbackIPv4,
          upstreamPort,
          timeout: const Duration(seconds: 10),
        );
        remote.add(headerBytes);
        for (final c in remainingChunks) {
          remote.add(c);
        }
        _pipeBidirectional(client, remote, sub);
        return;
      }

      if (method == 'CONNECT') {
        final hp = target.split(':');
        final host = hp[0];
        final port = hp.length > 1 ? int.tryParse(hp[1]) ?? 443 : 443;
        remote = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 10),
        );
        client.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        for (final c in remainingChunks) {
          remote.add(c);
        }
        _pipeBidirectional(client, remote, sub);
      } else {
        final uri = Uri.tryParse(target);
        if (uri == null || uri.host.isEmpty) {
          client.destroy();
          return;
        }
        final port = uri.hasPort ? uri.port : 80;
        remote = await Socket.connect(
          uri.host,
          port,
          timeout: const Duration(seconds: 10),
        );
        final path = uri.path.isEmpty ? '/' : uri.path;
        final query = uri.hasQuery ? '?${uri.query}' : '';
        final rewrittenFirstLine = '$method $path$query ${parts[2]}';
        final restHeaders = headerStr.substring(firstLineEnd);
        remote.add(utf8.encode('$rewrittenFirstLine$restHeaders'));
        for (final c in remainingChunks) {
          remote.add(c);
        }
        _pipeBidirectional(client, remote, sub);
      }
    } catch (_) {
      remote?.destroy();
      client.destroy();
    }
  }

  void _pipeBidirectional(
    Socket client,
    Socket remote,
    StreamSubscription<List<int>> clientSub,
  ) {
    clientSub.onData((data) {
      try {
        remote.add(data);
      } catch (_) {
        client.destroy();
        remote.destroy();
      }
    });
    clientSub.onDone(() => remote.destroy());
    clientSub.onError((_) => remote.destroy());
    clientSub.resume();

    remote.listen(
      (data) {
        try {
          client.add(data);
        } catch (_) {
          client.destroy();
          remote.destroy();
        }
      },
      onDone: () => client.destroy(),
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }

  int _findHeaderEnd(List<int> data) {
    for (var i = 0; i <= data.length - 4; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }
}
