import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'subscription.dart';

const _repo = 'SASUN1488/netkings-app';
const _channel = MethodChannel('netkings/vpn');

/// A newer GitHub release than this build, with the file for this platform.
class Update {
  final String version, page, url, file;
  final int size;
  Update(this.version, this.page, this.url, this.file, this.size);
}

/// "0.10.1" > "0.9.3"
bool newer(String a, String b) {
  List<int> p(String v) => v.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final x = p(a), y = p(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  return false;
}

Future<String> _assetSuffix() async {
  if (Platform.isWindows) return '-windows-x64.zip';
  if (Platform.isLinux) return '-linux-x64.tar.gz';
  final d = await _channel.invokeMapMethod<String, String>('device');
  return (d?['abi'] ?? '').contains('arm64') ? '-android-arm64.apk' : '-android-armv7.apk';
}

/// null = up to date (or GitHub is unreachable: nothing to show then).
Future<Update?> checkUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'));
    req.headers
      ..set(HttpHeaders.userAgentHeader, 'NetKings/$appVersion')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) return null;
    final r = jsonDecode(body) as Map<String, dynamic>;
    final v = (r['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (!newer(v, appVersion)) return null;
    final suffix = await _assetSuffix();
    for (final a in r['assets'] as List<dynamic>? ?? []) {
      final name = a['name'] as String;
      if (name.endsWith(suffix)) {
        return Update(v, r['html_url'] as String, a['browser_download_url'] as String, name, (a['size'] as num).toInt());
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Android: download the APK (progress 0..1) and hand it to the system installer (same signing key, so it
/// installs over this version and keeps the subscription).
Future<void> installAndroid(Update u, void Function(double) progress) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/updates')..createSync(recursive: true);
  for (final f in dir.listSync()) {
    f.deleteSync();
  }
  final file = File('${dir.path}/${u.file}');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(u.url));
    req.headers.set(HttpHeaders.userAgentHeader, 'NetKings/$appVersion');
    final resp = await req.close();
    if (resp.statusCode != 200) throw HttpException('GitHub ответил ${resp.statusCode}');
    final sink = file.openWrite();
    var got = 0;
    await for (final chunk in resp) {
      sink.add(chunk);
      got += chunk.length;
      progress(u.size > 0 ? got / u.size : 0);
    }
    await sink.close();
    if (u.size > 0 && got != u.size) throw const HttpException('файл скачался не полностью');
  } finally {
    client.close(force: true);
  }
  await _channel.invokeMethod('installApk', {'path': file.path});
}
