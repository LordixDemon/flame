import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('build_shaders compiles the shader pairs of a mixed source folder '
      'into another folder and leaves everything else alone', () async {
    final temp = Directory.systemTemp.createTempSync('flame3d_build_cli');
    addTearDown(() => temp.deleteSync(recursive: true));
    final src = Directory('${temp.path}/src')..createSync();
    final out = Directory('${temp.path}/out')..createSync();

    File('${src.path}/tint.vert').writeAsStringSync('''
#version 460 core

in vec3 vertexPosition;

#include <flame_3d/camera.glsl>

void main() {
  gl_Position = camera.viewProjection * vec4(vertexPosition, 1.0);
}
''');
    File('${src.path}/tint.frag').writeAsStringSync('''
#version 460 core

#include "tint_color.glsl"

out vec4 outColor;

void main() {
  outColor = tintColor();
}
''');
    // A chunk included by the pair, a lone stage and an unrelated file.
    File('${src.path}/tint_color.glsl').writeAsStringSync('''
vec4 tintColor() {
  return vec4(1.0, 0.5, 0.25, 1.0);
}
''');
    File('${src.path}/unfinished.frag').writeAsStringSync('not a shader');
    File('${src.path}/notes.txt').writeAsStringSync('notes');
    final otherBundle = File('${out.path}/other.shaderbundle')
      ..writeAsStringSync('another build');
    final readme = File('${out.path}/README.md')..writeAsStringSync('readme');

    final result = await Process.run('dart', [
      'run',
      'bin/build_shaders.dart',
      '--src',
      src.path,
      '--out',
      out.path,
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(File('${out.path}/tint.shaderbundle').lengthSync(), greaterThan(0));
    expect(File('${out.path}/unfinished.shaderbundle').existsSync(), isFalse);
    expect(otherBundle.readAsStringSync(), 'another build');
    expect(readme.readAsStringSync(), 'readme');
    expect(
      out.listSync().map((f) => f.uri.pathSegments.last).toSet(),
      {'tint.shaderbundle', 'other.shaderbundle', 'README.md'},
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
