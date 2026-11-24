import 'package:flutter_test/flutter_test.dart';
import 'package:netkings/src/appearance.dart';

void main() {
  test('appearance survives a round trip and repairs a bad file', () {
    final a = Appearance()
      ..mode = 'amoled'
      ..colors = 'teal'
      ..button = 'slide'
      ..blocks = ['servers', 'power', 'subscription']
      ..hidden = {'subscription'};
    final b = Appearance.fromJson(a.toJson());
    expect(b.toJson(), a.toJson());

    // unknown values -> defaults; a block from a newer version is dropped, a missing one comes back at the end;
    // the connect button can never be hidden
    final c = Appearance.fromJson({
      'mode': 'neon',
      'font': 'comic',
      'button': 'laser',
      'blocks': ['subscription', 'radar', 'power', 'power'],
      'hidden': ['power', 'servers', 'radar'],
      'wallDim': 5,
    });
    expect(c.mode, 'dark');
    expect(c.font, 'flex');
    expect(c.button, 'glow');
    expect(c.blocks, ['subscription', 'power', 'servers']);
    expect(c.hidden, {'servers'});
    expect(c.wallDim, .85);
  });
}
