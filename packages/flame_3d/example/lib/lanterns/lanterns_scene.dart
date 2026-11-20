import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d_example/pool/pool_meshes.dart';
import 'package:flame_3d_example/pool/pool_scene.dart';

/// Many small lights around the pool of a [PoolScene] at dusk: lanterns on
/// the paving round the pool, the lit windows of two rows of houses along
/// its far sides, and paper lanterns drifting on the water. With the two
/// lamps of the pool, the scene has [lights] point lights (at least 16),
/// each reaching a little over a unit, lit through `World3D.lightGrid`.
///
/// The lanterns of the paving are drawn in one instanced draw, the floating
/// ones in another, and the houses are one mesh: the draws do not grow with
/// the lights.
class LanternsScene({
  /// The point lights of the scene, the two lamps of the pool included.
  final int lights = 64,

  /// How many of the [lights] to add, the two lamps of the pool included
  /// (all of them by default): the same scene with fewer lights, to compare
  /// what the lights cost.
  final int? keepLights,
}) {
  /// The lanterns standing on the paving.
  final List<LightComponent> lanterns = [];

  /// The lights in front of the windows of the houses.
  final List<LightComponent> windows = [];

  /// The lights of the paper lanterns drifting on the water.
  final List<LightComponent> floating = [];

  /// The lights of [lanterns], [windows] and [floating] the scene adds to
  /// its world: all of them, or the first [keepLights].
  final List<LightComponent> added = [];

  final List<MeshComponent> _floatingMeshes = [];
  final List<Vector3> _drift = [];
  final List<double> _flicker = [];

  final StylizedMaterial _glow = StylizedMaterial(
    emissiveColor: const Color(0xFFFFD58A),
  );
  final StylizedMaterial _houses = StylizedMaterial(
    emissiveColor: const Color(0xFFFFC870),
    specularStrength: 0.1,
  );
  final StylizedMaterial _paper = StylizedMaterial(
    emissiveColor: const Color(0xFFFFB070),
  );

  /// The height of the paving (the top of the quay).
  static const double ground = PoolScene.quayHeight;

  /// How many lights of each kind a scene of [total] lights has, the two
  /// lamps of the pool aside: (lanterns, windows, floating lanterns).
  static (int, int, int) share(int total) {
    final rest = math.max(14, total - 2);
    final lanterns = (rest * 0.36).round();
    final floating = (rest * 0.24).round();
    return (lanterns, rest - lanterns - floating, floating);
  }

  /// The components of the scene, to add to the world of a [PoolScene].
  List<Component3D> build() {
    final (lanternCount, windowCount, floatingCount) = share(lights);
    final random = math.Random(5);
    const warm = [
      Color(0xFFFFB45E),
      Color(0xFFFFC27A),
      Color(0xFFFF9F55),
      Color(0xFFFFD08F),
    ];

    // Lanterns on the paving, round the pool on one ring (two beyond 50).
    final rings = lanternCount > 50 ? 2 : 1;
    final posts = <MeshComponent>[];
    final postMesh = _post().mesh(_glow);
    for (var ring = 0; ring < rings; ring++) {
      final count = ring == 0
          ? (lanternCount / rings).ceil()
          : lanternCount - (lanternCount / rings).ceil();
      final hx = 5.0 + ring * 1.1;
      final hy = 4.0 + ring * 1.1;
      final perimeter = 4 * (hx + hy);
      for (var i = 0; i < count; i++) {
        final at = _alongRectangle(
          hx,
          hy,
          perimeter * (i + 0.5 * ring) / count,
        );
        posts.add(MeshComponent(mesh: postMesh, position: at));
        lanterns.add(
          LightComponent.point(
            position: Vector3(at.x, at.y, ground + 0.72),
            color: warm[random.nextInt(warm.length)],
            intensity: 1.5,
            range: 1.45,
          ),
        );
        _flicker.add(random.nextDouble() * 10);
      }
    }

    // Two rows of houses along the far sides of the pool, their windows
    // facing it: a light just in front of each window.
    final houses = PoolMeshBuilder();
    const windowsPerHouse = 4;
    final houseCount = (windowCount / windowsPerHouse).ceil();
    final alongY = (houseCount / 2).ceil();
    var placed = 0;
    for (var h = 0; h < houseCount; h++) {
      final row = h < alongY ? 0 : 1;
      final index = row == 0 ? h : h - alongY;
      final count = row == 0 ? alongY : houseCount - alongY;
      final along = -6.2 + 12.4 * (index + 0.5) / count;
      // Row 0 along the far side y = -6.4, facing +y; row 1 along the far
      // side x = -7.4, facing +x: beyond both rings of lanterns.
      final center = row == 0
          ? Vector3(along, -6.4, ground)
          : Vector3(-7.4, along * 0.82, ground);
      final width = math.min(1.25, 12.4 / count - 0.25);
      final lit = math.min(windowsPerHouse, windowCount - placed);
      _house(houses, center, width, facingX: row == 1, windows: lit);
      for (var w = 0; w < lit; w++) {
        final (u, height) = _windowSpot(w, width);
        final position = row == 0
            ? Vector3(center.x + u, center.y + 0.62, ground + height)
            : Vector3(center.x + 0.62, center.y + u, ground + height);
        windows.add(
          LightComponent.point(
            position: position,
            color: warm[(h + w) % warm.length],
            intensity: 1.1,
            range: 1.1,
          ),
        );
      }
      placed += lit;
    }

    // Paper lanterns drifting on the water.
    final paperMesh = _paperLantern().mesh(_paper);
    for (var i = 0; i < floatingCount; i++) {
      final drift = Vector3(
        (random.nextDouble() * 2 - 1) * (PoolScene.halfLength - 0.6),
        (random.nextDouble() * 2 - 1) * (PoolScene.halfWidth - 0.6),
        random.nextDouble() * math.pi * 2,
      );
      _drift.add(drift);
      final mesh = MeshComponent(
        mesh: paperMesh,
        position: Vector3(drift.x, drift.y, 0.02),
      );
      _floatingMeshes.add(mesh);
      floating.add(
        LightComponent.point(
          position: Vector3(drift.x, drift.y, 0.3),
          color: i.isEven ? const Color(0xFFFF9A6A) : const Color(0xFFFFC07A),
          intensity: 1.2,
          range: 1.1,
        ),
      );
    }

    final keep = keepLights;
    if (keep == null) {
      added.addAll([...lanterns, ...windows, ...floating]);
    } else {
      // The first lights of each kind, in turn.
      var left = math.max(0, keep - 2);
      final most = math.max(
        lanterns.length,
        math.max(windows.length, floating.length),
      );
      for (var i = 0; left > 0 && i < most; i++) {
        for (final list in [lanterns, windows, floating]) {
          if (left > 0 && i < list.length) {
            added.add(list[i]);
            left--;
          }
        }
      }
    }
    return [
      ...added,
      ...posts,
      MeshComponent(mesh: houses.mesh(_houses)),
      ..._floatingMeshes,
    ];
  }

  /// Moves the scene to [time], in seconds: the paper lanterns drift and
  /// bob, and the flames of the lanterns flicker a little.
  void setTime(double time) {
    for (var i = 0; i < floating.length; i++) {
      final d = _drift[i];
      final angle = d.z + time * 0.18 * (i.isEven ? 1 : -1);
      final x = d.x + math.cos(angle) * 0.45;
      final y = d.y + math.sin(angle * 1.3) * 0.3;
      final bob = math.sin(time * 1.7 + d.z * 3) * 0.015;
      _floatingMeshes[i].position.setValues(x, y, 0.02 + bob);
      floating[i].position.setValues(x, y, 0.3 + bob);
    }
    for (var i = 0; i < lanterns.length; i++) {
      final phase = _flicker[i] + time * 7;
      (lanterns[i].source as PointLight).intensity =
          1.5 + 0.08 * math.sin(phase) + 0.05 * math.sin(phase * 2.3);
    }
  }

  // The point at [distance] along the rectangle of half sizes [hx] and [hy]
  // round the origin, on the paving.
  static Vector3 _alongRectangle(double hx, double hy, double distance) {
    final sides = [2 * hx, 2 * hy, 2 * hx, 2 * hy];
    var d = distance % (4 * (hx + hy));
    for (var side = 0; side < 4; side++) {
      if (d <= sides[side]) {
        return switch (side) {
          0 => Vector3(-hx + d, -hy, ground),
          1 => Vector3(hx, -hy + d, ground),
          2 => Vector3(hx - d, hy, ground),
          _ => Vector3(-hx, hy - d, ground),
        };
      }
      d -= sides[side];
    }
    return Vector3(-hx, -hy, ground);
  }

  // Where window [w] of a house of [width] is: along the front, and high.
  static (double, double) _windowSpot(int w, double width) {
    final column = w % 2;
    final row = w ~/ 2;
    return ((column - 0.5) * width * 0.5, row == 0 ? 0.32 : 0.78);
  }

  // A house of [width] centered at [center], its front towards +y (or +x
  // with [facingX]), with [windows] lit windows on it.
  static void _house(
    PoolMeshBuilder b,
    Vector3 center,
    double width, {
    required bool facingX,
    required int windows,
  }) {
    const depth = 1.1;
    const height = 1.05;
    const roof = 0.55;
    const walls = [
      Color(0xFFC9B9A0),
      Color(0xFFB8A58E),
      Color(0xFFD2C2A8),
      Color(0xFFA9988A),
    ];
    final wall = walls[(center.x * 3 + center.y * 7).round().abs() % 4];
    // In the house's frame: u along its front, v towards its front.
    Vector3 at(double u, double v, double z) => facingX
        ? Vector3(center.x + v, center.y + u, center.z + z)
        : Vector3(center.x + u, center.y + v, center.z + z);
    final hw = width / 2;
    const hd = depth / 2;
    final min = at(-hw, -hd, 0);
    final max = at(hw, hd, height);
    b.box(
      Vector3(math.min(min.x, max.x), math.min(min.y, max.y), center.z),
      Vector3(
        math.max(min.x, max.x),
        math.max(min.y, max.y),
        center.z + height,
      ),
      wall,
      footShade: 0.6,
    );
    // The roof: two slopes and the two gables, the ridge along the front.
    const roofColor = Color(0xFF7A4A3A);
    // A quad facing [outward], whatever the order of its corners.
    void quad(
      Vector3 a,
      Vector3 bb,
      Vector3 c,
      Vector3 d,
      Color color,
      Vector3 outward, {
      double emissive = 0,
    }) {
      final normal = (bb - a).cross(d - a);
      if (normal.dot(outward) >= 0) {
        b.quad(a, bb, c, d, color, emissive: emissive);
      } else {
        b.quad(a, d, c, bb, color, emissive: emissive);
      }
    }

    final up = Vector3(0, 0, 1);
    final front = at(0, 1, 0) - at(0, 0, 0);
    final side = at(1, 0, 0) - at(0, 0, 0);
    quad(
      at(-hw - 0.06, hd + 0.08, height),
      at(hw + 0.06, hd + 0.08, height),
      at(hw + 0.06, 0, height + roof),
      at(-hw - 0.06, 0, height + roof),
      roofColor,
      front + up,
    );
    quad(
      at(hw + 0.06, -hd - 0.08, height),
      at(-hw - 0.06, -hd - 0.08, height),
      at(-hw - 0.06, 0, height + roof),
      at(hw + 0.06, 0, height + roof),
      roofColor,
      up - front,
    );
    for (final s in [-1.0, 1.0]) {
      final u = s * hw;
      final a = at(u, hd, height);
      var c = at(u, -hd, height);
      var top = at(u, 0, height + roof);
      final outward = side * s;
      if ((c - a).cross(top - a).dot(outward) < 0) {
        final swap = c;
        c = top;
        top = swap;
      }
      final first = b.vertex(a, outward, wall);
      b
        ..vertex(c, outward, wall)
        ..vertex(top, outward, wall)
        ..triangle(first, first + 1, first + 2);
    }
    // The windows: panes just in front of the wall, glowing when lit.
    for (var w = 0; w < 4; w++) {
      final (u, z) = _windowSpot(w, width);
      final glow = w < windows;
      const half = 0.11;
      quad(
        at(u - half, hd + 0.012, z - 0.13),
        at(u + half, hd + 0.012, z - 0.13),
        at(u + half, hd + 0.012, z + 0.13),
        at(u - half, hd + 0.012, z + 0.13),
        glow ? const Color(0xFFFFE0A0) : const Color(0xFF3A4458),
        front,
        emissive: glow ? 1 : 0,
      );
    }
  }

  // A lantern on a short post.
  static PoolMeshBuilder _post() => PoolMeshBuilder()
    ..box(
      Vector3(-0.035, -0.035, 0),
      Vector3(0.035, 0.035, 0.62),
      const Color(0xFF2E323C),
    )
    ..box(
      Vector3(-0.08, -0.08, 0.62),
      Vector3(0.08, 0.08, 0.8),
      const Color(0xFFFFE2A8),
      emissive: 1,
      footShade: 1,
    )
    ..box(
      Vector3(-0.1, -0.1, 0.8),
      Vector3(0.1, 0.1, 0.84),
      const Color(0xFF2E323C),
    );

  // A paper lantern on a little float.
  static PoolMeshBuilder _paperLantern() => PoolMeshBuilder()
    ..box(
      Vector3(-0.1, -0.1, -0.03),
      Vector3(0.1, 0.1, 0.03),
      const Color(0xFF6B4E3A),
    )
    ..box(
      Vector3(-0.06, -0.06, 0.03),
      Vector3(0.06, 0.06, 0.2),
      const Color(0xFFFFC890),
      emissive: 1,
      footShade: 1,
    );
}
