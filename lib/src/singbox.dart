import 'dart:convert';
import 'dart:io';

import 'settings.dart';
import 'subscription.dart';

/// Russian domains go direct (as on the servers): faster, and they pass the mobile operators' whitelists anyway.
const _directSuffixes = ['.ru', '.su', '.xn--p1ai'];

/// The core's clash API on localhost: traffic / ping / which server is in use, and forced re-tests.
const clashPort = 29190;

/// Local proxy (login "nk" + the clash secret) into the picked country: the monitor keeps one connection open
/// through it, so the shown ping is one round trip, not the handshakes of a fresh connection.
const pingPort = 29191;

/// Leaf outbound tag `exit-entry-protocol` (e.g. "fi-relay3-grpc") -> protocol label.
String protocolOf(String tag) => tag.split('-').last;

/// The single servers of the subscription ("fi-relay3-grpc"), in subscription order (groups left out).
List<String> leafTags(Subscription sub) => [
  for (final o in sub.outbounds)
    if (o['type'] != 'urltest' && o['type'] != 'selector') '${o['tag']}',
];

/// Local proxy port that goes through [leaf] only: the server list measures every server the same way as
/// the ping of the server in use (through the core, over a kept connection).
int leafPingPort(Subscription sub, String leaf) => pingPort + 1 + leafTags(sub).indexOf(leaf);

/// Full sing-box config for the core: the subscription's outbounds + a selector on the picked country
/// (or on one server the user picked by hand), TUN inbound (Android VpnService / desktop TUN), DNS over the tunnel.
String buildConfig(Subscription sub, String selected, [Settings? settings, String secret = '']) {
  final s = settings ?? Settings();
  final groups = ['auto', ...sub.countries.map((c) => c.tag), if (leafTags(sub).contains(selected)) selected];
  final dns = dnsServers[s.dns]!.$2;
  final entryIps = {
    for (final o in sub.outbounds)
      if (InternetAddress.tryParse('${o['server']}') case final a?)
        '${a.address}/${a.type == InternetAddressType.IPv6 ? 128 : 32}',
  }.toList();
  final config = {
    'log': {'level': 'warn', 'timestamp': true},
    'dns': {
      'servers': [
        {'type': 'https', 'tag': 'remote', 'server': dns, 'detour': 'proxy'},
        {'type': 'udp', 'tag': 'direct', 'server': '77.88.8.8'},
      ],
      'rules': [
        if (s.directRu) {'domain_suffix': _directSuffixes, 'server': 'direct'},
      ],
      'final': 'remote',
      'strategy': 'ipv4_only',
    },
    'inbounds': [
      {
        'type': 'tun',
        'tag': 'tun',
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 1500,
        'auto_route': true,
        'strict_route': true,
        // home network stays outside the tunnel: replies to LAN peers (LocalSend, printers, Chromecast, the
        // router page) otherwise go into the TUN and die. 172.16/12 and fc00::/7 are left in: the TUN itself
        // lives there (172.19.0.0/30, fdfe:dcba:9876::/126).
        // The entry servers too: the app's own pings to them (TCP / ICMP / NK Ping) must take the real way — inside
        // the TUN the stack itself answers a TCP handshake at once (a fake "3 ms"). The core's own connections
        // to them never go through the TUN anyway.
        'route_exclude_address': [
          ...['10.0.0.0/8', '192.168.0.0/16', '169.254.0.0/16', '224.0.0.0/4', 'fe80::/10'],
          ...entryIps,
        ],
        'stack': 'mixed',
      },
      if (secret.isNotEmpty)
        for (final (tag, port) in [
          ('ping', pingPort),
          for (final l in leafTags(sub)) ('ping:$l', leafPingPort(sub, l)),
        ])
          {
            'type': 'mixed',
            'tag': tag,
            'listen': '127.0.0.1',
            'listen_port': port,
            'users': [
              {'username': 'nk', 'password': secret},
            ],
          },
    ],
    'outbounds': [
      ..._outbounds(sub, s.protocol),
      {
        'type': 'selector',
        'tag': 'proxy',
        'outbounds': groups,
        'default': groups.contains(selected) ? selected : 'auto',
      },
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {
      'rules': [
        if (secret.isNotEmpty) ...[
          {
            'inbound': ['ping'],
            'outbound': 'proxy',
          },
          for (final l in leafTags(sub))
            {
              'inbound': ['ping:$l'],
              'outbound': l,
            },
        ],
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
        {'ip_is_private': true, 'outbound': 'direct'},
        if (s.directRu) {'domain_suffix': _directSuffixes, 'outbound': 'direct'},
      ],
      'final': 'proxy',
      'auto_detect_interface': true,
      'default_domain_resolver': 'direct',
    },
    'experimental': {
      'cache_file': {'enabled': true},
      'clash_api': {'external_controller': '127.0.0.1:$clashPort', 'secret': secret},
    },
  };
  return jsonEncode(config);
}

/// The subscription's outbounds; with a fixed protocol the urltest groups keep only that protocol's servers
/// (a country without it keeps all of them). Every group drops the connections of a server it leaves, so
/// apps reconnect through the new one at once.
List<Map<String, dynamic>> _outbounds(Subscription sub, String protocol) {
  final out = <Map<String, dynamic>>[];
  for (final o in sub.outbounds) {
    final m = Map<String, dynamic>.from(o as Map);
    if (m['type'] == 'urltest') {
      final all = List<String>.from(m['outbounds'] as List);
      final only = protocol == 'auto' ? all : all.where((t) => protocolOf(t) == protocol).toList();
      m['outbounds'] = only.isEmpty ? all : only;
      m['interrupt_exist_connections'] = true;
    }
    out.add(m);
  }
  return out;
}
