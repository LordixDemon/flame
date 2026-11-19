import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Cone Mesh', () {
    test('can create a simple cone', () {
      const segments = 17;

      final cone = ConeMesh(
        radius: 1.0,
        height: 1.0,
        segments: segments,
        material: SpatialMaterial(),
      );

      expect(
        cone.surfaces,
        hasLength(2),
      );

      // The base has a center and a ring; the side a ring that repeats its
      // first vertex (for the texture seam) and one tip per segment.
      expect(
        cone.surfaces.map((s) => s.vertexCount).toList(),
        equals([segments + 1, segments + 1 + segments]),
      );

      expect(
        cone.surfaces.map((s) => s.indexCount).toSet(),
        equals({segments * 3}),
      );
    });

    test('shades the side up to the tip and keeps UVs across the seam', () {
      const segments = 8;
      final side = ConeMesh(
        radius: 1,
        height: 2,
        segments: segments,
        material: SpatialMaterial(),
      ).surfaces.last;
      final stride = side.layout.strideInFloats;
      final data = side.vertexData;
      for (var t = 0; t < side.indexCount; t += 3) {
        final corners = [for (var k = 0; k < 3; k++) side.indices[t + k]];
        // Every corner leans outwards (no normal straight up at the tip).
        for (final v in corners) {
          expect(data[v * stride + 10], lessThan(0.99));
        }
        // No triangle spans more than one slice of the texture.
        final us = [for (final v in corners) data[v * stride + 3]];
        final spread =
            us.reduce((a, b) => a > b ? a : b) -
            us.reduce((a, b) => a < b ? a : b);
        expect(spread, lessThanOrEqualTo(1 / segments + 1e-6));
      }
    });
  });
}
