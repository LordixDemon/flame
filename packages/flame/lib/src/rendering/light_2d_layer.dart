import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/painting.dart';

/// Radial 2D point light source for [Light2DLayer].
class PointLight2D({
  required Vector2 position,
  this.radius = 160.0,
  this.color = const Color(0xFFFFE6B8),
  this.intensity = 1.0,
  this.flickerAmplitude = 0.0,
  this.flickerSpeed = 8.0,
  this.castsShadows = true,
  this.enabled = true,
}) {
  /// Light center in world coordinates.
  final Vector2 position = position.clone();

  /// Maximum falloff radius in world units.
  double radius;

  /// Light color tint.
  Color color;

  /// Light brightness multiplier (`0.0 .. 2.0`).
  double intensity;

  /// Optional organic intensity oscillation amplitude (`0.0 .. 1.0`).
  double flickerAmplitude;

  /// Angular speed (rad/s) for flicker oscillation.
  double flickerSpeed;

  /// Whether [ShadowOccluder2D] segments cast shadows against this light.
  bool castsShadows;

  /// Whether this light is active.
  bool enabled;

  /// Evaluates current effective intensity at [elapsedSeconds].
  double effectiveIntensity(double elapsedSeconds) {
    if (!enabled || intensity <= 0.0 || radius <= 0.0) {
      return 0.0;
    }
    if (flickerAmplitude <= 0.0) {
      return intensity;
    }
    final wave =
        0.65 * math.sin(elapsedSeconds * flickerSpeed) +
        0.35 * math.sin(elapsedSeconds * flickerSpeed * 2.37 + 1.3);
    return (intensity * (1.0 + wave * flickerAmplitude)).clamp(0.0, 4.0);
  }
}

/// Directional cone 2D spotlight for [Light2DLayer].
class SpotLight2D({
  required Vector2 position,
  this.directionRad = 0.0,
  this.coneAngleRad = 0.7853981633974483, // pi / 4
  this.radius = 220.0,
  this.color = const Color(0xFFFFF2D6),
  this.intensity = 1.0,
  this.castsShadows = true,
  this.enabled = true,
}) {
  /// Spotlight origin in world coordinates.
  final Vector2 position = position.clone();

  /// Aiming direction in radians (`0` = `+X`, `pi/2` = `+Y`).
  double directionRad;

  /// Full cone aperture angle in radians.
  double coneAngleRad;

  /// Cone reach distance in world units.
  double radius;

  /// Spotlight color tint.
  Color color;

  /// Brightness multiplier.
  double intensity;

  /// Whether [ShadowOccluder2D] segments cast shadows inside this cone.
  bool castsShadows;

  /// Whether this spotlight is active.
  bool enabled;
}

/// 2D line-segment or convex-polygon shadow caster for [Light2DLayer].
class ShadowOccluder2D._(
  final List<Vector2> vertices, {
  required final bool closed,
  var bool enabled = true,
}) {
  /// Creates a single wall segment occluder from [a] to [b].
  factory ShadowOccluder2D.segment(
    Vector2 a,
    Vector2 b, {
    bool enabled = true,
  }) {
    return ShadowOccluder2D._(
      <Vector2>[a.clone(), b.clone()],
      closed: false,
      enabled: enabled,
    );
  }

  /// Creates a closed rectangular shadow occluder from [rect].
  factory ShadowOccluder2D.rect(Rect rect, {bool enabled = true}) {
    return ShadowOccluder2D._(
      <Vector2>[
        Vector2(rect.left, rect.top),
        Vector2(rect.right, rect.top),
        Vector2(rect.right, rect.bottom),
        Vector2(rect.left, rect.bottom),
      ],
      closed: true,
      enabled: enabled,
    );
  }

  /// Creates a closed polygon occluder from [points] (counter-clockwise or
  /// clockwise).
  factory ShadowOccluder2D.polygon(
    List<Vector2> points, {
    bool enabled = true,
  }) {
    assert(points.length >= 3, 'Polygon occluder needs at least 3 vertices');
    return ShadowOccluder2D._(
      points.map((p) => p.clone()).toList(growable: false),
      closed: true,
      enabled: enabled,
    );
  }

  /// Computes the extruded shadow shape(s) cast by this occluder from
  /// `(lx, ly)` out to [extrudeDistance], appending them to [outPath].
  ///
  /// Each shadow-casting edge `(a, b)` contributes one closed polygon: the
  /// edge itself plus far points pushed [extrudeDistance] beyond `a` and `b`
  /// along the light rays. When the edge subtends a wide angle at the light (a
  /// wall close to it), extra far points are inserted every `60` degrees or
  /// less, so the far side of the polygon never cuts back inside the light
  /// radius and everything behind the edge stays in shadow. [extrudeDistance]
  /// should be at least `1.16 * radius` for that guarantee (`Light2DLayer`
  /// passes `2.2 * radius`).
  ///
  /// Returns the number of shadow polygons appended (one per casting edge).
  int appendShadowQuads({
    required double lx,
    required double ly,
    required double radius,
    required double extrudeDistance,
    required Path outPath,
  }) {
    if (!enabled || vertices.length < 2) {
      return 0;
    }
    final edgeCount = closed ? vertices.length : vertices.length - 1;
    final rSq = radius * radius;
    var quads = 0;

    // For closed polygons, compute centroid to identify back-facing vs
    // light-facing edges cleanly regardless of winding order.
    var cx = 0.0;
    var cy = 0.0;
    if (closed) {
      for (var i = 0; i < vertices.length; i++) {
        cx += vertices[i].x;
        cy += vertices[i].y;
      }
      cx /= vertices.length;
      cy /= vertices.length;
    }

    for (var i = 0; i < edgeCount; i++) {
      final a = vertices[i];
      final b = vertices[(i + 1) % vertices.length];

      // Quick distance check from light to segment midpoint.
      final mx = (a.x + b.x) * 0.5;
      final my = (a.y + b.y) * 0.5;
      final edgeHalfLenSq =
          ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)) * 0.25;
      final dmx = mx - lx;
      final dmy = my - ly;
      if (dmx * dmx + dmy * dmy >
          rSq + edgeHalfLenSq + 2.0 * radius * math.sqrt(edgeHalfLenSq)) {
        continue;
      }

      if (closed) {
        // Outward normal points away from polygon centroid (cx, cy).
        final ex = b.x - a.x;
        final ey = b.y - a.y;
        var nx = -ey;
        var ny = ex;
        if (nx * (mx - cx) + ny * (my - cy) < 0) {
          nx = -nx;
          ny = -ny;
        }
        // Cast shadow from back-facing silhouette edges (or front-facing — both
        // work; front-facing avoids self-occluding interior!). Wait: if we
        // extrude BACK-facing edges (`nx * (lx - mx) + ny * (ly - my) < 0`),
        // the occluder itself stays lit while the region behind it is shadowed!
        final toLightX = lx - mx;
        final toLightY = ly - my;
        if (nx * toLightX + ny * toLightY >= 0) {
          continue;
        }
      }

      final dax = a.x - lx;
      final day = a.y - ly;
      final dbx = b.x - lx;
      final dby = b.y - ly;
      final lenA = math.sqrt(dax * dax + day * day);
      final lenB = math.sqrt(dbx * dbx + dby * dby);
      if (lenA <= 1e-4 || lenB <= 1e-4) {
        continue;
      }

      final farAx = a.x + (dax / lenA) * extrudeDistance;
      final farAy = a.y + (day / lenA) * extrudeDistance;
      final farBx = b.x + (dbx / lenB) * extrudeDistance;
      final farBy = b.y + (dby / lenB) * extrudeDistance;

      outPath
        ..moveTo(a.x, a.y)
        ..lineTo(b.x, b.y)
        ..lineTo(farBx, farBy);

      // The straight chord farB -> farA passes at `d * cos(theta / 2)` from
      // the light, where `theta` is the angle the edge subtends: for a wide
      // edge near the light that is well inside the light radius and the
      // region behind the edge would stay lit. Walk the far side around the
      // light in steps of at most 60 degrees instead (`cos(30) = 0.87`).
      final cross = dax * dby - day * dbx;
      final dot = dax * dbx + day * dby;
      final theta = math.atan2(cross, dot); // signed angle from a to b
      final spans = (theta.abs() / (math.pi / 3.0)).ceil();
      if (spans > 1) {
        final farDist = math.max(lenA, lenB) + extrudeDistance;
        final angA = math.atan2(day, dax);
        for (var k = spans - 1; k >= 1; k--) {
          final ang = angA + theta * (k / spans);
          outPath.lineTo(
            lx + math.cos(ang) * farDist,
            ly + math.sin(ang) * farDist,
          );
        }
      }

      outPath
        ..lineTo(farAx, farAy)
        ..close();
      quads++;
    }
    return quads;
  }
}

/// Dynamic 2D lighting & shadow-casting world layer component.
///
/// Accumulates an [ambientColor] darkness map with additive [PointLight2D] and
/// [SpotLight2D] radial/cone gradients, masking each shadow-casting light
/// against [ShadowOccluder2D] geometry, and composites onto the scene via
/// [compositeBlendMode] (`BlendMode.modulate` by default).
class Light2DLayer({
  var Color ambientColor = const Color(0xFF282C44),
  var ui.BlendMode compositeBlendMode = ui.BlendMode.modulate,
  var Rect? bounds,
  var bool respectGraphicsQuality = true,
  super.priority = 900,
  super.key,
}) extends Component {
  /// Registered point lights.
  final List<PointLight2D> pointLights = <PointLight2D>[];

  /// Registered directional spotlights.
  final List<SpotLight2D> spotLights = <SpotLight2D>[];

  /// Registered 2D shadow occluders.
  final List<ShadowOccluder2D> occluders = <ShadowOccluder2D>[];

  double _elapsed = 0.0;
  int _lastRenderedLights = 0;
  int _lastShadowQuads = 0;

  final Paint _compositePaint = Paint();
  final Paint _ambientPaint = Paint();
  final Paint _lightPaint = Paint()..blendMode = ui.BlendMode.plus;
  final Paint _shadowMaskPaint = Paint()
    ..color = const Color(0xFF000000)
    ..blendMode = ui.BlendMode.dstOut
    ..isAntiAlias = true;
  final Path _shadowPath = Path();

  /// Lights drawn during the most recent [render] pass.
  int get lastRenderedLights => _lastRenderedLights;

  /// Extruded shadow quads drawn during the most recent [render] pass.
  int get lastShadowQuads => _lastShadowQuads;

  @override
  void update(double dt) {
    _elapsed += dt;
  }

  @override
  void render(Canvas canvas) {
    final activeBounds =
        bounds ?? CameraComponent.currentCamera?.visibleWorldRect;
    if (activeBounds == null || activeBounds.isEmpty) {
      _lastRenderedLights = 0;
      _lastShadowQuads = 0;
      return;
    }

    var allowShadows = occluders.isNotEmpty;
    if (allowShadows && respectGraphicsQuality) {
      final game = CameraComponent.currentCamera?.findGame();
      if (game is FlameGame && !game.graphics.effectiveShadowsEnabled) {
        allowShadows = false;
      }
    }

    _compositePaint.blendMode = compositeBlendMode;
    canvas.saveLayer(activeBounds, _compositePaint);

    _ambientPaint.color = ambientColor;
    canvas.drawRect(activeBounds, _ambientPaint);

    var renderedLights = 0;
    var renderedQuads = 0;

    for (var i = 0; i < pointLights.length; i++) {
      final light = pointLights[i];
      final effInt = light.effectiveIntensity(_elapsed);
      if (effInt <= 1e-3) {
        continue;
      }
      final r = light.radius;
      final lightRect = Rect.fromCircle(
        center: Offset(light.position.x, light.position.y),
        radius: r,
      );
      if (!activeBounds.overlaps(lightRect)) {
        continue;
      }

      renderedLights++;
      final centerColor = Color.fromARGB(
        255,
        (light.color.r * effInt * 255.0).round().clamp(0, 255),
        (light.color.g * effInt * 255.0).round().clamp(0, 255),
        (light.color.b * effInt * 255.0).round().clamp(0, 255),
      );
      final gradient = ui.Gradient.radial(
        Offset(light.position.x, light.position.y),
        r,
        <Color>[centerColor, const Color(0x00000000)],
        const <double>[0.0, 1.0],
      );

      final castHere = allowShadows && light.castsShadows;
      if (castHere) {
        _shadowPath.reset();
        var lightQuads = 0;
        for (var j = 0; j < occluders.length; j++) {
          lightQuads += occluders[j].appendShadowQuads(
            lx: light.position.x,
            ly: light.position.y,
            radius: r,
            extrudeDistance: r * 2.2,
            outPath: _shadowPath,
          );
        }
        if (lightQuads > 0) {
          renderedQuads += lightQuads;
          canvas.saveLayer(lightRect, _lightPaint);
          final fillPaint = Paint()..shader = gradient;
          canvas.drawCircle(
            Offset(light.position.x, light.position.y),
            r,
            fillPaint,
          );
          canvas.drawPath(_shadowPath, _shadowMaskPaint);
          canvas.restore();
          continue;
        }
      }

      _lightPaint.shader = gradient;
      canvas.drawCircle(
        Offset(light.position.x, light.position.y),
        r,
        _lightPaint,
      );
      _lightPaint.shader = null;
    }

    for (var i = 0; i < spotLights.length; i++) {
      final spot = spotLights[i];
      if (!spot.enabled || spot.intensity <= 1e-3 || spot.radius <= 0.0) {
        continue;
      }
      final r = spot.radius;
      final spotRect = Rect.fromCircle(
        center: Offset(spot.position.x, spot.position.y),
        radius: r,
      );
      if (!activeBounds.overlaps(spotRect)) {
        continue;
      }

      renderedLights++;
      final effInt = spot.intensity.clamp(0.0, 4.0);
      final centerColor = Color.fromARGB(
        255,
        (spot.color.r * effInt * 255.0).round().clamp(0, 255),
        (spot.color.g * effInt * 255.0).round().clamp(0, 255),
        (spot.color.b * effInt * 255.0).round().clamp(0, 255),
      );
      final gradient = ui.Gradient.radial(
        Offset(spot.position.x, spot.position.y),
        r,
        <Color>[centerColor, const Color(0x00000000)],
        const <double>[0.0, 1.0],
      );

      final halfCone = (spot.coneAngleRad * 0.5).clamp(0.02, math.pi);
      final conePath = Path()
        ..moveTo(spot.position.x, spot.position.y)
        ..arcTo(
          spotRect,
          spot.directionRad - halfCone,
          halfCone * 2.0,
          false,
        )
        ..close();

      final castHere = allowShadows && spot.castsShadows;
      if (castHere) {
        _shadowPath.reset();
        var spotQuads = 0;
        for (var j = 0; j < occluders.length; j++) {
          spotQuads += occluders[j].appendShadowQuads(
            lx: spot.position.x,
            ly: spot.position.y,
            radius: r,
            extrudeDistance: r * 2.2,
            outPath: _shadowPath,
          );
        }
        if (spotQuads > 0) {
          renderedQuads += spotQuads;
          canvas.saveLayer(spotRect, _lightPaint);
          final fillPaint = Paint()..shader = gradient;
          canvas.drawPath(conePath, fillPaint);
          canvas.drawPath(_shadowPath, _shadowMaskPaint);
          canvas.restore();
          continue;
        }
      }

      _lightPaint.shader = gradient;
      canvas.drawPath(conePath, _lightPaint);
      _lightPaint.shader = null;
    }

    canvas.restore();
    _lastRenderedLights = renderedLights;
    _lastShadowQuads = renderedQuads;
  }
}
