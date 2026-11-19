import 'dart:math' as math;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Compound centers of mass', () {
    test('a rotated nested compound places its center of mass with the '
        'rotation (not the inverse rotation)', () {
      // An inner compound whose mass sits at +X, rotated 90 degrees about Z:
      // its geometry and its center of mass end up at +Y.
      final inner = CompoundShape3D([
        CompoundChildShape3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.1)),
          position: Vector3(1, 0, 0),
        ),
      ]);
      final outer = CompoundShape3D([
        CompoundChildShape3D(
          shape: inner,
          rotation: Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 2),
        ),
      ]);
      final aabb = outer.computeLocalAabb();
      expect((aabb.min.y + aabb.max.y) / 2, closeTo(1, 1e-5));
      expect(outer.localCenterOfMass.x, closeTo(0, 1e-5));
      expect(outer.localCenterOfMass.y, closeTo(1, 1e-5));
    });
  });

  group('Rope tube frames', () {
    test('rings stay perpendicular to a helical rope', () {
      const segments = 32;
      const step = 0.5;
      const radius = 0.1;
      // Helix whose segments are as long as the rope's rest segments.
      const rest = 2.0 / segments;
      final chord = 2 * radius * math.sin(step / 2);
      final rise = math.sqrt(rest * rest - chord * chord);
      final rope = XpbdRope3D(
        startPoint: Vector3.zero(),
        endPoint: Vector3(0, -2, 0),
        segmentCount: segments,
        radialSegments: 8,
        radius: 0.02,
        autoStep: false,
      );
      for (var i = 0; i <= segments; i++) {
        rope.setParticlePosition(
          i,
          Vector3(
            radius * math.cos(i * step),
            -rise * i,
            radius * math.sin(i * step),
          ),
        );
      }
      rope.step(1e-6);
      final positions = rope.surface.positions;
      const cols = 8 + 1;
      var worst = 0.0;
      for (var i = 1; i < segments; i++) {
        final prev = rope.getParticlePosition(i - 1);
        final next = rope.getParticlePosition(i + 1);
        final center = rope.getParticlePosition(i);
        final tangent = (next - prev)..normalize();
        for (var j = 0; j < cols; j++) {
          final o = (i * cols + j) * 3;
          final offset = Vector3(
            positions[o] - center.x,
            positions[o + 1] - center.y,
            positions[o + 2] - center.z,
          );
          worst = math.max(worst, offset.dot(tangent).abs() / 0.02);
        }
      }
      expect(worst, lessThan(0.05));
    });
  });
}
