import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'subscription.dart';

const ideaMaxBytes = 5 << 20; // the backend takes up to 5 MB

/// Picks a picture for «Предложить иконку». null = cancelled; a String starting with '!' = a problem to show.
Future<String?> pickIdeaPicture() async {
  final List<PlatformFile> r;
  try {
    r = await FilePicker.pickFiles(type: FileType.image, dialogTitle: 'Иконка для NetKings');
  } catch (_) {
    return '!Не удалось открыть выбор картинки';
  }
  final path = r.isEmpty ? null : r.first.path;
  if (path == null) return null;
  if (await File(path).length() > ideaMaxBytes) return '!Картинка больше 5 МБ';
  return path;
}

/// Sends the picture to the NetKings team (backend `POST /idea/<subscription token>` → the owner's Telegram).
/// Returns the toast text.
Future<String> sendIdea(String subUrl, String path) async {
  final u = Uri.parse(subUrl);
  final token = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
  final url = Uri(scheme: u.scheme, host: u.host, port: u.port, path: '/idea/$token');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final bytes = await File(path).readAsBytes();
    final req = await client.postUrl(url);
    req.headers
      ..set(HttpHeaders.userAgentHeader, 'NetKings/$appVersion (${Platform.operatingSystem})')
      ..contentType = ContentType.binary
      ..contentLength = bytes.length;
    req.add(bytes);
    final resp = await req.close().timeout(const Duration(seconds: 120));
    await resp.drain<void>();
    return switch (resp.statusCode) {
      200 => 'Спасибо! Картинка у нас 💜 Лучшие добавим в обновлении',
      429 => 'Можно отправить не больше 5 картинок в день',
      400 => 'Нужна картинка PNG, JPG или WebP',
      413 => 'Картинка больше 5 МБ',
      404 => 'Подписка не найдена',
      _ => 'Не получилось отправить, попробуй позже',
    };
  } catch (_) {
    return 'Нет связи с сервером, попробуй позже';
  } finally {
    client.close(force: true);
  }
}
