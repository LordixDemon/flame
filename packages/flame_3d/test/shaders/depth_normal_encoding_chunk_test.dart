import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shaders of the depth-normal prepass share one encoding', () {
    const chunk = '#include <flame_3d/depth_normal_encoding.glsl>';
    final encoding = File(
      'shaders/flame_3d/depth_normal_encoding.glsl',
    ).readAsStringSync();
    expect(encoding, contains('vec4 encodeDepthNormal(vec3 viewPos)'));

    for (final path in [
      'shaders/flame_3d/depth_normal_fragment.glsl',
      'shaders/billboard_depth_normal.frag',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains(chunk), reason: path);
      expect(source, contains('encodeDepthNormal(fragViewPos)'), reason: path);
      // The encoding itself is not repeated.
      expect(source, isNot(contains('65535.0')), reason: path);
      expect(source, isNot(contains('dFdx')), reason: path);
    }
  });
}
