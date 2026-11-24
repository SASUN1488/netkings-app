import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'secrets.dart';
import 'subscription.dart';

/// Blocks of the home screen the user can move / hide (the header and the update card stay on top).
const blockNames = {'power': 'Кнопка подключения', 'servers': 'Серверы', 'subscription': 'Подписка'};

const modes = {'system': 'Авто', 'dark': 'Тёмная', 'light': 'Светлая', 'amoled': 'Чёрная'};

const fonts = {
  'flex': ('NetKings', 'Жирный и круглый, по умолчанию'),
  'flex_plain': ('Google Sans', 'Тот же шрифт, обычные буквы'),
  'system': ('Системный', 'Шрифт телефона / компьютера'),
  'custom': ('Свой', 'Файл .ttf или .otf'),
};

const buttons = {'glow': 'Сияние', 'shape': 'Expressive', 'pill': 'Пилюля', 'slide': 'Свайп'};

/// Accent colours; "netkings" is the brand purple + green, "system" = Material You (Android 12+),
/// "wallpaper" = taken from the own wallpaper.
const seeds = <String, (String, Color)>{
  'netkings': ('NetKings', Color(0xFF9D6BFF)),
  'blue': ('Синий', Color(0xFF4C7DFF)),
  'teal': ('Бирюза', Color(0xFF14B8A6)),
  'green': ('Зелёный', Color(0xFF3DBE5C)),
  'orange': ('Оранжевый', Color(0xFFFF8A3D)),
  'red': ('Красный', Color(0xFFE5484D)),
  'pink': ('Розовый', Color(0xFFFF5FA2)),
};

/// How the app looks, kept in appearance.json. Changes apply at once (nothing here touches the core).
class Appearance {
  String mode = 'dark';
  String colors = 'netkings';
  String font = 'flex';
  String? fontFile; // the own font, copied into the app's folder
  String button = 'glow';
  List<String> blocks = blockNames.keys.toList();
  Set<String> hidden = {};
  double wallDim = .45; // how much the own wallpaper is darkened
  bool haptics = true;

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'colors': colors,
    'font': font,
    'fontFile': fontFile,
    'button': button,
    'blocks': blocks,
    'hidden': hidden.toList(),
    'wallDim': wallDim,
    'haptics': haptics,
  };

  static Appearance fromJson(Map<String, dynamic> j) {
    final a = Appearance()
      ..mode = modes.containsKey(j['mode']) ? j['mode'] as String : 'dark'
      ..colors = j['colors'] is String ? j['colors'] as String : 'netkings'
      ..font = fonts.containsKey(j['font']) ? j['font'] as String : 'flex'
      ..fontFile = j['fontFile'] as String?
      ..button = buttons.containsKey(j['button']) ? j['button'] as String : 'glow'
      ..wallDim = ((j['wallDim'] as num?) ?? .45).toDouble().clamp(0, .85)
      ..haptics = j['haptics'] as bool? ?? true;
    // keep known blocks in the saved order, add ones a newer version brought at the end
    final saved = [
      for (final b in (j['blocks'] as List? ?? []))
        if (blockNames.containsKey(b)) b as String,
    ];
    a.blocks = [...saved.toSet(), ...blockNames.keys.where((b) => !saved.contains(b))];
    a.hidden = {
      for (final b in (j['hidden'] as List? ?? []))
        if (blockNames.containsKey(b) && b != 'power') b as String,
    };
    return a;
  }

  Appearance copy() => fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

final appearance = ValueNotifier<Appearance>(Appearance());

/// Bumped whenever the colours change (theme, accent, wallpaper, platform light / dark): the app rebuilds.
final colorsVersion = ValueNotifier<int>(0);

Color? _systemAccent; // Android 12+: the colour Material You took from the phone's wallpaper
bool get hasSystemColors => _systemAccent != null;
ColorScheme? _imageDark, _imageLight; // from a tinting picture
String? _customFamily; // the loaded own font

Future<void> loadAppearance() async {
  try {
    final t = await Store.read('appearance.json');
    if (t != null) {
      appearance.value = Appearance.fromJson(jsonDecode(t) as Map<String, dynamic>);
    } else if (look.value?.file ?? false) {
      // up to 0.2.6 the own wallpaper (code 1337) always coloured the app: keep it so after the update
      appearance.value = Appearance()..colors = 'wallpaper';
    }
  } on FormatException {
    // broken file: defaults
  }
  if (Platform.isAndroid) {
    try {
      final c = await const MethodChannel('netkings/vpn').invokeMethod<int>('systemAccent');
      if (c != null) _systemAccent = Color(c);
    } catch (_) {}
  }
  await _loadFont(appearance.value);
  await refreshColors();
}

Future<void> saveAppearance(Appearance a) async {
  final fontChanged = a.font != appearance.value.font || a.fontFile != appearance.value.fontFile;
  if (fontChanged) await _loadFont(a);
  appearance.value = a;
  await refreshColors();
  await Store.write('appearance.json', jsonEncode(a.toJson()));
}

Future<void> _loadFont(Appearance a) async {
  final f = a.fontFile;
  if (a.font != 'custom' || f == null || !File(f).existsSync()) return;
  final family = 'NkCustom${f.hashCode}'; // a new name per file: a family cannot be reloaded
  if (_customFamily == family) return;
  try {
    final bytes = await File(f).readAsBytes();
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    _customFamily = family;
  } catch (_) {
    _customFamily = null;
  }
}

/// Own font: pick a .ttf / .otf, copy it into the app's folder. Returns the toast text.
Future<String> pickFont() async {
  final List<PlatformFile> r;
  try {
    r = await FilePicker.pickFiles(type: FileType.any, dialogTitle: 'Шрифт .ttf / .otf');
  } catch (_) {
    return 'Не удалось открыть выбор файла';
  }
  final src = r.isEmpty ? null : r.first.path;
  if (src == null) return 'Файл не выбран';
  final ext = src.toLowerCase().split('.').last;
  if (ext != 'ttf' && ext != 'otf') return 'Нужен файл шрифта .ttf или .otf';
  final dst = '${(await getApplicationSupportDirectory()).path}/font_${DateTime.now().millisecondsSinceEpoch}.$ext';
  await File(src).copy(dst);
  final old = appearance.value.fontFile;
  final a = appearance.value.copy()
    ..font = 'custom'
    ..fontFile = dst;
  await _loadFont(a);
  if (_customFamily == null) {
    await File(dst).delete().catchError((_) => File(dst));
    return 'Этот файл не открывается как шрифт';
  }
  await saveAppearance(a);
  if (old != null && old != dst) await File(old).delete().catchError((_) => File(old));
  return 'Шрифт установлен';
}

/// Colours taken from a picture: an easter-egg look that tints, or the own wallpaper with colours "wallpaper".
Future<void> refreshColors() async {
  final l = look.value;
  final img = l != null && (l.tint || (l.file && appearance.value.colors == 'wallpaper')) ? l.image : null;
  if (img != null) {
    try {
      _imageDark = await ColorScheme.fromImageProvider(provider: img, brightness: Brightness.dark);
      _imageLight = await ColorScheme.fromImageProvider(provider: img, brightness: Brightness.light);
    } catch (_) {
      _imageDark = _imageLight = null;
    }
  } else {
    _imageDark = _imageLight = null;
  }
  _cache = null;
  colorsVersion.value++;
}

/// Light or dark right now.
Brightness get brightness => switch (appearance.value.mode) {
  'light' => Brightness.light,
  'system' => PlatformDispatcher.instance.platformBrightness,
  _ => Brightness.dark,
};

const _nkDark = Color(0xFF0B0A10);

/// Brand colours: picked, or the pick is not available (Material You off the phone, "wallpaper" without one).
bool get _brand {
  final c = appearance.value.colors;
  if (_imageDark != null) return false;
  if (c == 'system') return _systemAccent == null;
  return !seeds.containsKey(c) || c == 'netkings';
}

ColorScheme schemeFor(Brightness b) {
  final a = appearance.value;
  final dark = b == Brightness.dark;
  var s = dark ? _imageDark : _imageLight;
  if (s == null) {
    final seed = _brand ? seeds['netkings']!.$2 : (a.colors == 'system' ? _systemAccent! : seeds[a.colors]!.$2);
    s = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    if (_brand) {
      // the brand: violet + green on near-black (dark) / soft violet white (light)
      s = dark
          ? s.copyWith(
              primary: const Color(0xFF9D6BFF),
              onPrimary: Colors.white,
              primaryContainer: const Color(0xFF3B2A66),
              onPrimaryContainer: const Color(0xFFE9DDFF),
              secondary: const Color(0xFF2EE59D),
              onSecondary: const Color(0xFF00391F),
              surface: _nkDark,
              surfaceContainerLowest: const Color(0xFF07060B),
              surfaceContainerLow: const Color(0xFF110F17),
              surfaceContainer: const Color(0xFF15131D),
              surfaceContainerHigh: const Color(0xFF1D1A27),
              surfaceContainerHighest: const Color(0xFF262233),
              outlineVariant: const Color(0xFF272335),
              onSurfaceVariant: const Color(0xFF8E8AA0),
            )
          : s.copyWith(primary: const Color(0xFF7C4DFF), onPrimary: Colors.white, secondary: const Color(0xFF0E9E68));
    }
  }
  if (a.mode == 'amoled' && dark) {
    s = s.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF080808),
      surfaceContainer: const Color(0xFF101010),
      surfaceContainerHigh: const Color(0xFF181818),
      surfaceContainerHighest: const Color(0xFF222222),
    );
  }
  return s;
}

/// The font of the texts: family + the roundness axis of Google Sans Flex.
String? get fontFamily => switch (appearance.value.font) {
  'flex' || 'flex_plain' => 'GoogleSansFlex',
  'custom' => _customFamily ?? 'GoogleSansFlex',
  _ => null,
};

/// Google Sans Flex has no Cyrillic: Nunito (bold + round too) draws the Russian letters; an own font may
/// lack them as well.
List<String>? get fontFallback =>
    appearance.value.font == 'flex' || appearance.value.font == 'custom' ? const ['Nunito'] : null;

List<FontVariation>? get fontVariations =>
    appearance.value.font == 'flex' || (appearance.value.font == 'custom' && _customFamily == null)
    ? const [FontVariation('ROND', 100)]
    : null;

/// The default text is bold with the NetKings font (like the lyrics on the user's desktop).
bool get boldText => appearance.value.font == 'flex';

/// Colours of the app's own widgets, from the colour scheme in use.
class Palette {
  final Color bg, surface, high, line, accent, accent2, muted, onAccent, fg;
  const Palette({
    required this.bg,
    required this.surface,
    required this.high,
    required this.line,
    required this.accent,
    required this.accent2,
    required this.muted,
    required this.onAccent,
    required this.fg,
  });

  factory Palette.of(ColorScheme s, {required bool brand, required bool wall}) => Palette(
    bg: s.surface,
    // panels let the wallpaper show through a little
    surface: wall ? s.surfaceContainer.withValues(alpha: .86) : s.surfaceContainer,
    high: wall ? s.surfaceContainerHighest.withValues(alpha: .9) : s.surfaceContainerHighest,
    line: s.outlineVariant,
    accent: s.primary,
    accent2: brand ? s.secondary : s.tertiary,
    muted: s.onSurfaceVariant,
    onAccent: s.onPrimary,
    fg: s.onSurface,
  );
}

(Brightness, int)? _cacheKey;
Palette? _cache;

Palette get palette {
  final key = (brightness, colorsVersion.value);
  if (_cache == null || _cacheKey != key) {
    _cache = Palette.of(schemeFor(key.$1), brand: _brand, wall: look.value != null);
    _cacheKey = key;
  }
  return _cache!;
}
