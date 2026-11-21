import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// An OpenGL ES driver need not run a `for` loop as written unless its bounds
// are constants (GLSL ES 1.00, appendix A). The Android emulator's ran the
// shadow filter's `for (int y = -radius; y <= radius + 1; y++)`, `radius`
// from a uniform, wrongly for every radius above 0 (at 0 it starts at 0 and
// was right), while loops from a constant start to a bound read from a
// uniform (the lights) ran right there.
//
// So every loop of the shaders starts at a constant: in the GLSL sources, and
// in the shipped bundles, whose OpenGL ES (and Metal) text impellerc writes
// from them. The shadow filters, which read the shadow map in their loops,
// have constant bounds at both ends.

/// `for (int <index> = <start>; <condition>;`
final _loop = RegExp(r'for\s*\(\s*int\s+(\w+)\s*=\s*([^;]*);\s*([^;]*);');

final _integer = RegExp(r'^-?\d+$');

/// The text of a GLSL source without its comments.
String _code(File file) => file
    .readAsStringSync()
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp('//[^\n]*'), '');

List<File> _sources() =>
    Directory('shaders')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'\.(vert|frag|glsl)$').hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  test('every loop of the shader sources starts at a constant', () {
    final sources = _sources();
    expect(sources, isNotEmpty);
    final found = <String>[];
    for (final file in sources) {
      for (final match in _loop.allMatches(_code(file))) {
        final start = match.group(2)!.trim();
        if (!_integer.hasMatch(start)) {
          found.add('${file.path}: ${match.group(0)}');
        }
      }
    }
    expect(found, isEmpty, reason: 'Loops that start at a run-time value');
  });

  test('every loop of shadows.glsl has constant bounds', () {
    final loops = _loop
        .allMatches(_code(File('shaders/flame_3d/shadows.glsl')))
        .toList();
    // The two filters' loops over rows and columns, the loop over the
    // cascades and the two over the spot light tiles.
    expect(loops, hasLength(7));
    for (final match in loops) {
      final index = match.group(1)!;
      final condition = match.group(3)!.trim();
      expect(match.group(2)!.trim(), matches(_integer), reason: match[0]);
      expect(
        condition,
        matches(RegExp('^$index\\s*<=?\\s*-?\\d+\$')),
        reason: match[0],
      );
    }
  });

  test('every loop of the shipped shader bundles starts at a constant', () {
    final bundles =
        Directory('assets/shaders')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.shaderbundle'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(bundles, isNotEmpty);
    final found = <String>[];
    var loops = 0;
    for (final bundle in bundles) {
      final text = latin1.decode(bundle.readAsBytesSync());
      for (final match in _loop.allMatches(text)) {
        loops++;
        if (!_integer.hasMatch(match.group(2)!.trim())) {
          found.add('${bundle.uri.pathSegments.last}: ${match.group(0)}');
        }
      }
    }
    expect(loops, greaterThan(0));
    expect(found, isEmpty, reason: 'Loops that start at a run-time value');
  });
}
