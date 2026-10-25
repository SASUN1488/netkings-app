import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const appVersion = '0.1.0';

/// One country the user can pick: a urltest group over all entries x protocols of that exit.
class Country {
  final String id, tag, flag, name;
  Country(this.id, this.tag, this.flag, this.name);
}

/// The app variant of the vpnctl subscription (User-Agent "NetKings/..."): ready sing-box outbounds + metadata.
class Subscription {
  final String url;
  final Map<String, dynamic> raw;
  Subscription(this.url, this.raw);

  String get brand => raw['brand'] as String? ?? 'NetKings VPN';
  String get bot => raw['bot'] as String? ?? '';
  String? get notice => raw['notice'] as String?;
  bool get active => raw['active'] == true;
  DateTime? get expires =>
      raw['expires'] == null ? null : DateTime.fromMillisecondsSinceEpoch((raw['expires'] as int) * 1000);
  List<dynamic> get outbounds => raw['outbounds'] as List<dynamic>? ?? [];
  List<Country> get countries => [
        for (final c in raw['countries'] as List<dynamic>? ?? [])
          Country(c['id'], c['tag'], c['flag'] ?? '', c['name'] ?? c['id']),
      ];
}

/// Subscription URL / cached body / device id kept in the app's private files.
class Store {
  static Future<File> _file(String name) async => File('${(await getApplicationSupportDirectory()).path}/$name');

  static Future<String?> read(String name) async {
    final f = await _file(name);
    return await f.exists() ? await f.readAsString() : null;
  }

  static Future<void> write(String name, String text) async => (await _file(name)).writeAsString(text);

  static Future<void> delete(String name) async {
    final f = await _file(name);
    if (await f.exists()) await f.delete();
  }

  /// Stable per-install id sent as x-hwid: the backend counts devices (limit 3) by it.
  static Future<String> deviceId() async {
    final have = await read('hwid');
    if (have != null && have.isNotEmpty) return have;
    final r = Random.secure();
    final id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await write('hwid', id);
    return id;
  }
}

/// `netkings://import/<url>` (url may be percent-encoded) or a plain https subscription link.
String? parseSubscriptionLink(String text) {
  var s = text.trim();
  if (s.startsWith('netkings://')) {
    s = s.replaceFirst(RegExp(r'^netkings://(import|add)/'), '');
    s = Uri.decodeComponent(s);
  }
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || !u.path.contains('/sub/')) return null;
  return s;
}

const _channel = MethodChannel('netkings/vpn');

Future<Subscription> fetchSubscription(String url) async {
  final hwid = await Store.deviceId();
  var model = Platform.localHostname, os = Platform.operatingSystem;
  if (Platform.isAndroid) {
    final d = await _channel.invokeMapMethod<String, String>('device');
    model = d?['model'] ?? model;
    os = d?['os'] ?? os;
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers
      ..set(HttpHeaders.userAgentHeader, 'NetKings/$appVersion (${Platform.operatingSystem})')
      ..set('x-hwid', hwid)
      ..set('x-device-os', os)
      ..set('x-device-model', model);
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 404) throw const SubscriptionError('Подписка не найдена — проверь ссылку в боте');
    if (resp.statusCode != 200) throw SubscriptionError('Сервер ответил ${resp.statusCode}');
    final Map<String, dynamic> raw;
    try {
      raw = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw const SubscriptionError('Неверный ответ сервера');
    }
    await Store.write('sub_url', url);
    await Store.write('sub.json', body);
    return Subscription(url, raw);
  } finally {
    client.close(force: true);
  }
}

Future<Subscription?> cachedSubscription() async {
  final url = await Store.read('sub_url'), body = await Store.read('sub.json');
  if (url == null || body == null) return null;
  try {
    return Subscription(url, jsonDecode(body) as Map<String, dynamic>);
  } on FormatException {
    return null;
  }
}

class SubscriptionError implements Exception {
  final String message;
  const SubscriptionError(this.message);
  @override
  String toString() => message;
}
