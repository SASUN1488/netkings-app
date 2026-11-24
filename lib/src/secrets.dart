import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:path_provider/path_provider.dart';

import 'appearance.dart';
import 'subscription.dart';

/// Easter eggs. The secret field: Settings → tap the "NetKings x.y.z" line 7 times quickly.
/// A typed code is trimmed and lowercased; its sha256 is looked up in [eggs], so the codes themselves
/// are not in the (public, GPL) source. New egg: `python3 -c "import hashlib;print(hashlib.sha256(b'code').hexdigest())"`.
typedef Egg = Future<String> Function(); // returns the toast text

/// A look an egg switches on: a wallpaper, optionally the picture behind every panel, optionally the
/// app's colours taken from the picture (Material You: ColorScheme.fromImageProvider).
class Look {
  final String id, asset; // asset: a bundled picture, or a file path when [file]
  final bool file; // the user's own picture (code 1337), copied into the app's folder
  final bool panels; // the picture is also the background of every panel
  final bool tint; // accent / panel / line colours follow the picture
  final double dim; // how much the wallpaper is darkened (0..1), for readable text
  const Look(this.id, this.asset, {this.panels = false, this.tint = false, this.dim = .35, this.file = false});

  ImageProvider get image => file ? FileImage(File(asset)) : AssetImage(asset);
}

const looks = {
  'joker': Look('joker', 'assets/eggs/joker.jpg', panels: true),
  'dog': Look('dog', 'assets/eggs/dog.jpg', tint: true, dim: .55),
  'tom': Look('tom', 'assets/eggs/tom.jpg', tint: true, dim: .55),
};

/// The look on now (null = the plain app); its colours: appearance.dart.
final look = ValueNotifier<Look?>(null);

Future<void> _setLook(Look? l) async {
  look.value = l;
  await refreshColors();
  await Store.write('egg_look', l?.id ?? '');
}

/// The user's own wallpaper: a copy of the picked picture (a new name each time, so no stale image cache).
/// Its colours follow it when Оформление → Цвета is «Из обоев».
Look _custom(String path) => Look('custom', path, file: true);

bool get hasOwnWallpaper => look.value?.id == 'custom';

/// Оформление → Обои → «Убрать» (also turns an easter-egg look off).
Future<void> clearWallpaper() async {
  if (appearance.value.colors == 'wallpaper') await saveAppearance(appearance.value.copy()..colors = 'netkings');
  await _setLook(null);
}

/// Оформление → Обои → «Выбрать» (code 1337 does the same): a picture becomes the wallpaper. Cancelling the
/// picker while the own wallpaper is on switches it off only for the code.
Future<String> pickWallpaper() => _pickOwn(fromCode: false);

Future<String> _pickOwn({bool fromCode = true}) async {
  final List<PlatformFile> r;
  try {
    r = await FilePicker.pickFiles(type: FileType.image, dialogTitle: 'Свои обои');
  } catch (_) {
    return 'Не удалось открыть выбор картинки'; // e.g. Linux without zenity / kdialog
  }
  final src = r.isEmpty ? null : r.first.path;
  if (src == null) {
    if (look.value?.id != 'custom' || !fromCode) return 'Картинка не выбрана';
    await _setLook(null);
    return 'Обычная тема';
  }
  final dir = (await getApplicationSupportDirectory()).path;
  final old = await Store.read('egg_custom');
  final dst = '$dir/egg_custom_${DateTime.now().millisecondsSinceEpoch}';
  await File(src).copy(dst);
  try {
    await _setLook(_custom(dst));
  } catch (_) {
    await File(dst).delete().catchError((_) => File(dst));
    return 'Не получилось открыть картинку';
  }
  await Store.write('egg_custom', dst);
  if (old != null && old != dst) await File(old).delete().catchError((_) => File(old));
  return '🖼 Свои обои';
}

/// The same code again switches its look off; another code switches to its own look.
Egg _toggle(String id, String on) => () async {
  final l = look.value?.id == id ? null : looks[id];
  await _setLook(l);
  return l == null ? 'Обычная тема' : on;
};

final Map<String, Egg> eggs = {
  'cf23dc33d6aba13592a72190564ed18b2c0dae295f681ee0fddc4862f01225cf': _toggle('joker', '🃏 Why so serious?'),
  '9d693eeee1d1899cbc50b6d45df953d3835acf28ee869879b45565fccc814765': _toggle('dog', '🐶 Касса свободна'),
  'e1608f75c5d7813f3d4031cb30bfb786507d98137538ff8e128a6ff74e84e643': _toggle('tom', '😎 Tom'),
  '5db1fee4b5703808c48078a76768b155b421b210c0761cd6a5d223f4d99f1eaa': () => _pickOwn(),
};

/// Runs the egg for [code]: its toast text, or null = no such code.
Future<String?> runEgg(String code) async {
  final egg = eggs[sha256.convert(utf8.encode(code.trim().toLowerCase())).toString()];
  return egg == null ? null : await egg();
}

Future<void> loadEggs() async {
  final id = await Store.read('egg_look');
  final own = id == 'custom' ? await Store.read('egg_custom') : null;
  // 0.2.6 test builds kept the joker theme as egg_joker
  var l = own != null && File(own).existsSync()
      ? _custom(own)
      : looks[id] ?? (await Store.read('egg_joker') == '1' ? looks['joker'] : null);
  if (l != null && l.file) {
    try {
      await precacheImageless(l.image);
    } catch (_) {
      l = null; // the own picture is broken: plain app
    }
  }
  look.value = l;
}

/// Decodes the picture once (throws when it is not an image) without a BuildContext.
Future<void> precacheImageless(ImageProvider p) async {
  final c = Completer<void>();
  final s = p.resolve(ImageConfiguration.empty);
  late final ImageStreamListener li;
  li = ImageStreamListener(
    (_, _) {
      if (!c.isCompleted) c.complete();
      s.removeListener(li);
    },
    onError: (e, _) {
      if (!c.isCompleted) c.completeError(e);
      s.removeListener(li);
    },
  );
  s.addListener(li);
  return c.future.timeout(const Duration(seconds: 10));
}

/// Background picture of a panel (null = plain colour): darkened so the text on it stays readable.
DecorationImage? get panelImage {
  final l = look.value;
  if (l == null || !l.panels) return null;
  return DecorationImage(
    image: l.image,
    fit: BoxFit.cover,
    colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: .55), BlendMode.darken),
  );
}

/// The whole-app wallpaper behind the pages (null = none): darkened, or lightened in the light theme.
Widget? get wallpaper {
  final l = look.value;
  if (l == null) return null;
  final dim = l.file ? appearance.value.wallDim : l.dim;
  final light = brightness == Brightness.light;
  return Image(
    image: l.image,
    fit: BoxFit.cover,
    color: (light ? Colors.white : Colors.black).withValues(alpha: dim),
    colorBlendMode: light ? BlendMode.srcATop : BlendMode.darken,
  );
}
