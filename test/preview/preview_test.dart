// Local screenshots of screens (not part of CI): NK_PREVIEW=1 flutter test test/preview --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netkings/main.dart';
import 'package:netkings/src/appearance.dart';
import 'package:netkings/src/power_button.dart';
import 'package:netkings/src/settings.dart';

Future<void> font(String family, String path) async {
  await (FontLoader(family)..addFont(Future.value(File(path).readAsBytesSync().buffer.asByteData()))).load();
}

Future<void> shot(WidgetTester t, Widget w, Size size, String name, Brightness b) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: appTheme(b), home: w));
  await t.pump(const Duration(milliseconds: 700));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name.png'));
}

void main() {
  if (Platform.environment['NK_PREVIEW'] == null) return; // local tool, not a test
  final fl = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/.local/opt/flutter';
  setUpAll(() async {
    await font('GoogleSansFlex', 'assets/fonts/GoogleSansFlex.ttf');
    await font('Nunito', 'assets/fonts/Nunito.ttf');
    await font('MaterialIcons', '$fl/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  });

  Widget settings() => Scaffold(
    body: SafeArea(
      child: SettingsPage(
        settings: Settings(),
        subUrl: 'https://example.invalid/sub/0',
        update: null,
        onCheckUpdate: () async => null,
        onInstall: () {},
        embedded: true,
      ),
    ),
  );

  for (final (mode, colors) in [('dark', 'netkings'), ('light', 'teal'), ('amoled', 'orange')]) {
    testWidgets('settings $mode $colors', (t) async {
      appearance.value = Appearance()
        ..mode = mode
        ..colors = colors;
      colorsVersion.value++;
      await shot(t, settings(), const Size(412, 2600), 'settings_${mode}_$colors', brightness);
    });
  }

  testWidgets('buttons', (t) async {
    appearance.value = Appearance();
    colorsVersion.value++;
    Widget row(String style) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final (on, busy) in [(false, false), (false, true), (true, false)])
          SizedBox(
            width: 300,
            height: 220,
            child: Center(
              child: PowerButton(style: style, on: on, busy: busy, onTap: () {}),
            ),
          ),
      ],
    );
    await shot(
      t,
      Scaffold(body: Column(children: [for (final s in buttons.keys) row(s)])),
      const Size(940, 900),
      'buttons',
      Brightness.dark,
    );
  });
}
