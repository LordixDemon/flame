import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// The motif a [BarrierMaterial] repeats along its wall.
enum BarrierPattern() {
  /// No motif: the glow, the glint and the impacts only.
  plain,

  /// Chevrons pointing the way the pattern travels.
  chevrons,

  /// Diamond outlines, each with a dot at its center.
  diamonds,

  /// Rune-like dashes: stems of varying length with a dot, a caret or a bar,
  /// different from one motif to the next.
  dashes,
}

/// {@template barrier_material}
/// A translucent energy wall that stands around an area while something is
/// in play inside it, and lights up where it is hit.
///
/// It draws any mesh whose vertices carry the distance along the wall (in
/// scene units) in `vertexTexCoord.x`, the height up the wall (`0` at its
/// foot, `1` at its top) in `vertexTexCoord.y`, and the wall's normal in
/// `vertexNormal`: a band around a rectangle, a ring, a dome, any strip.
/// `BarrierMesh` builds the usual ones.
///
/// The wall is brightest at its foot and thins out above ([footColor],
/// [topColor], [heightFalloff], [footGlow]), and its near side, the side
/// whose outside faces the viewer, is thinner still ([nearSideFade]), so
/// that it never hides what stands inside it. [appear] raises it from its
/// foot and lowers it back. A
/// slow [pattern] of motifs travels along it, in a band above the foot; it
/// glints where it is seen edge-on ([glintStrength]); and [impact] sends a
/// ring of light across it from a point, with a flash around that point.
///
/// Advance [time] every frame: the pattern, the twinkle of its motifs and the
/// impacts follow it.
///
/// ```dart
/// final barrier = BarrierMaterial(pattern: BarrierPattern.chevrons);
/// final wall = BarrierMesh.roundedRectangle(
///   width: 6,
///   depth: 6,
///   height: 0.8,
///   cornerRadius: 0.4,
///   material: barrier,
/// );
/// barrier.fitPatternTo(wall.length, motifLength: 0.45);
/// world.add(MeshComponent(mesh: wall));
///
/// // Every frame:
/// barrier.time += dt;
/// // Where something hits it:
/// barrier.impact(hitPoint, color: const Color(0xFF7FD4FF));
/// ```
///
/// By default it is drawn with [RenderState.additive]: its light adds to what
/// is behind it and keeps the target's alpha, so in a `Scene3DComponent` it
/// adds onto the 2D art drawn below the layer without darkening it. It is
/// depth tested against the scene without writing depth, both faces are
/// drawn, and it is left out of the shadow passes ([castsShadows] is
/// `false`) and of the depth-normal prepass (which draws only opaque
/// materials). [RenderState.premultipliedAlphaBlend] and
/// [RenderState.alphaBlend] lay it over the scene instead, as a light veil
/// with an alpha of its brightest channel.
///
/// It writes display colors, like the other materials besides
/// `SpatialMaterial`: in an HDR scene target nothing is clamped, so an
/// [intensity] above `1` and stacked impacts go above white and bloom; in an
/// 8-bit target they clip.
///
/// Every barrier is one draw (its mesh has one surface). The appear factor,
/// the pattern and the impacts belong to the material, so give each barrier
/// that rises and is hit on its own its own material. Each instance's color
/// tints the wall and its alpha scales its light (`MeshComponent.color`).
///
/// Not available on the web: there are no WebGPU shaders for it.
/// {@endtemplate}
class BarrierMaterial({
  /// The color at the foot of the wall; its alpha scales the light there.
  var Color footColor = const Color(0xFFFFB45A),

  /// The color at the top of the wall; its alpha scales the light there.
  var Color topColor = const Color(0x4DFFF2D6),

  /// A multiplier of all the light of the wall. Above `1` the bright parts
  /// go above white, which an HDR scene target keeps (and bloom picks up).
  var double intensity = 0.8,

  /// How fast the light thins out up the wall: it is multiplied by
  /// `(1 - height) ^ heightFalloff`, `height` running from `0` at the foot to
  /// `1` at the top.
  var double heightFalloff = 1.8,

  /// The strength of a thin bright line along the foot.
  var double footGlow = 0.7,

  /// How far the wall has risen from its foot, from `0` (not drawn at all)
  /// to `1` (all of it). Animate it to raise and lower the wall.
  var double appear = 1,

  /// The softness of the rising front, as a fraction of the wall's height.
  var double appearSoftness = 0.15,

  /// The motif repeated along the wall.
  var BarrierPattern pattern = BarrierPattern.chevrons,

  /// The number of motifs per scene unit along the wall; see
  /// [fitPatternTo].
  var double patternScale = 2.5,

  /// How fast the pattern travels along the wall, in scene units per second
  /// (negative values travel the other way).
  var double patternSpeed = 0.3,

  /// The brightness of the motifs.
  var double patternStrength = 0.55,

  /// The top of the band of the wall the motifs fill, as a fraction of its
  /// height from the foot.
  var double patternHeight = 0.45,

  /// The length of the wall's closed loop, in scene units along it, or `0`
  /// for a wall that is not closed; see [fitPatternTo].
  var double patternLoopLength = 0,

  /// How much the near side of the wall, the side whose outside faces the
  /// viewer, is thinned out, from `0` (not at all) to `1` (only its impacts
  /// show): the far side shows behind what stands inside, the near side does
  /// not veil it. The wall's normals must point out of the enclosed area, as
  /// those of `BarrierMesh` do.
  var double nearSideFade = 0.7,

  /// The strength of the glint where the wall is seen edge-on.
  var double glintStrength = 0.35,

  /// How narrow that glint is: higher values keep it closer to the edges.
  var double glintPower = 4,

  /// How fast an impact's ring spreads, in scene units per second.
  var double impactRingSpeed = 2.5,

  /// The width of an impact's ring, in scene units.
  var double impactRingWidth = 0.07,

  /// How long an impact lasts, in seconds.
  var double impactDuration = 0.9,

  /// The radius of the flash around an impact's point, in scene units.
  var double impactFlashRadius = 0.3,
  RenderState renderState = RenderState.additive,
}) extends Material {
  /// {@macro barrier_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: const [RenderContext3D.cameraMatricesBlock, 'BarrierShape'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: const ['BarrierLook'],
        ),
      ) {
    if (kIsWeb) {
      throw UnsupportedError(
        'BarrierMaterial is not available on the web yet: it has no WebGPU '
        'shaders.',
      );
    }
    this.renderState = renderState;
    castsShadows = false;
  }

  static const String _bundle =
      'packages/flame_3d/assets/shaders/barrier_material.shaderbundle';

  /// The number of impacts a barrier shows at once: a new one replaces the
  /// oldest when all are in use.
  static const int maxImpacts = 4;

  /// The number of motifs after which the pattern of a wall that is not
  /// closed repeats.
  static const int openWallPeriod = 256;

  /// The time, in seconds, the pattern and the impacts follow: advance it
  /// every frame.
  double time = 0;

  // x, y, z, start time, r, g, b, strength per impact.
  final Float64List _impacts = Float64List(maxImpacts * 8);
  final Vector4 _value = Vector4.zero();
  final Matrix4 _inverse = Matrix4.zero();

  static const List<String> _positionKeys = [
    'BarrierLook.impactPositions[0]',
    'BarrierLook.impactPositions[1]',
    'BarrierLook.impactPositions[2]',
    'BarrierLook.impactPositions[3]',
  ];
  static const List<String> _colorKeys = [
    'BarrierLook.impactColors[0]',
    'BarrierLook.impactColors[1]',
    'BarrierLook.impactColors[2]',
    'BarrierLook.impactColors[3]',
  ];

  /// Shows an impact at [position] (in world space) at the current [time]:
  /// a ring of [color] spreading from it over the wall and a flash around
  /// it, scaled by [strength], for [impactDuration] seconds.
  ///
  /// It takes a free slot, or the oldest impact's when all [maxImpacts] are
  /// in use, and returns the slot's index. It allocates nothing. To hit a
  /// point given on the wall rather than in the world, see
  /// `BarrierMesh.pointOnWall`.
  int impact(
    Vector3 position, {
    Color color = const Color(0xFFFFFFFF),
    double strength = 1,
  }) {
    var slot = 0;
    var oldest = double.infinity;
    for (var i = 0; i < maxImpacts; i++) {
      if (!isImpactActive(i)) {
        slot = i;
        break;
      }
      final start = _impacts[i * 8 + 3];
      if (start < oldest) {
        oldest = start;
        slot = i;
      }
    }
    final o = slot * 8;
    _impacts
      ..[o] = position.x
      ..[o + 1] = position.y
      ..[o + 2] = position.z
      ..[o + 3] = time
      ..[o + 4] = color.r
      ..[o + 5] = color.g
      ..[o + 6] = color.b
      ..[o + 7] = strength * color.a;
    return slot;
  }

  /// Whether the impact in [slot] is still showing at the current [time].
  bool isImpactActive(int slot) {
    final o = slot * 8;
    if (!(_impacts[o + 7] > 0)) {
      return false;
    }
    final age = time - _impacts[o + 3];
    return age >= 0 && age < impactDuration;
  }

  /// The number of impacts showing at the current [time].
  int get activeImpactCount {
    var count = 0;
    for (var i = 0; i < maxImpacts; i++) {
      if (isImpactActive(i)) {
        count++;
      }
    }
    return count;
  }

  /// Removes every impact.
  void clearImpacts() => _impacts.fillRange(0, _impacts.length, 0);

  /// Sets [patternScale] so that a whole number of motifs of about
  /// [motifLength] scene units fits the closed loop of [loopLength] scene
  /// units (the `length` of a `BarrierMesh`), and [patternLoopLength] to it:
  /// the pattern then has no seam where the loop closes, and motifs that
  /// differ from one to the next ([BarrierPattern.dashes]) stay the same as
  /// they travel across that point.
  void fitPatternTo(double loopLength, {double motifLength = 0.4}) {
    assert(loopLength > 0, 'loopLength must be positive');
    assert(motifLength > 0, 'motifLength must be positive');
    final count = math.max(1, (loopLength / motifLength).round());
    patternScale = count / loopLength;
    patternLoopLength = loopLength;
  }

  /// The number of motifs after which the pattern repeats: those of the
  /// closed loop of [patternLoopLength], or [openWallPeriod].
  double get patternPeriod {
    if (patternLoopLength > 0 && patternScale > 0) {
      return math.max(1, (patternLoopLength * patternScale).roundToDouble());
    }
    return openWallPeriod.toDouble();
  }

  /// How far the pattern has travelled at the current [time], in motifs,
  /// wrapped to `[0, patternPeriod)`.
  double get patternOffset {
    final offset = time * patternSpeed * patternScale % patternPeriod;
    return offset.isFinite ? offset : 0;
  }

  @override
  void apply(RenderContext context) {
    final c = context as RenderContext3D;
    final appear = this.appear.clamp(0.0, 1.0);
    vertexShader.setVector4(
      'BarrierShape.params',
      _value..setValues(appear, 0, 0, 0),
    );

    final blend = renderState.blend;
    final shader = fragmentShader
      ..setColor('BarrierLook.footColor', footColor)
      ..setColor('BarrierLook.topColor', topColor)
      ..setVector4(
        'BarrierLook.shape',
        _value..setValues(appear, heightFalloff, intensity, footGlow),
      )
      ..setVector4(
        'BarrierLook.pattern',
        _value..setValues(
          pattern.index.toDouble(),
          patternScale,
          patternOffset,
          patternStrength,
        ),
      )
      ..setVector4(
        'BarrierLook.patternExtra',
        _value..setValues(
          patternHeight,
          patternPeriod,
          patternSpeed < 0 ? -1 : 1,
          time * _twinkleSpeed % (2 * math.pi),
        ),
      )
      ..setVector4(
        'BarrierLook.glint',
        _value..setValues(
          glintStrength,
          glintPower,
          blend == BlendState.alpha ? 0 : 1,
          appearSoftness,
        ),
      )
      ..setVector4(
        'BarrierLook.impactShape',
        _value..setValues(
          impactRingSpeed,
          impactRingWidth,
          impactDuration,
          impactFlashRadius,
        ),
      )
      ..setVector4(
        'BarrierLook.extra',
        _value..setValues(nearSideFade, 0, 0, 0),
      );
    _writeViewer(c, shader);
    for (var i = 0; i < maxImpacts; i++) {
      final o = i * 8;
      final active = isImpactActive(i);
      shader
        ..setVector4(
          _positionKeys[i],
          _value..setValues(
            _impacts[o],
            _impacts[o + 1],
            _impacts[o + 2],
            active ? time - _impacts[o + 3] : -1,
          ),
        )
        ..setVector4(
          _colorKeys[i],
          _value..setValues(
            _impacts[o + 4],
            _impacts[o + 5],
            _impacts[o + 6],
            active ? _impacts[o + 7] : 0,
          ),
        );
    }
  }

  /// The radians per second the motifs twinkle at.
  static const double _twinkleSpeed = 1.7;

  /// Writes where the viewer is: the camera's center of projection
  /// (`w = 1`), or the direction towards the viewer for a parallel
  /// projection (`w = 0`).
  ///
  /// Both come from the inverse of the view-projection matrix, the point or
  /// direction that the clip-space depth axis `(0, 0, 1, 0)` comes from, so
  /// they hold for oblique and mirroring projections too, such as the affine
  /// ones of `Scene3DComponent`.
  void _writeViewer(RenderContext3D context, Shader shader) {
    final inverse = _inverse..setFrom(context.viewProjection);
    final determinant = inverse.invert();
    final s = inverse.storage;
    var x = s[8];
    var y = s[9];
    var z = s[10];
    final w = s[11];
    final length = math.sqrt(x * x + y * y + z * z);
    if (determinant == 0 || !(length > 0)) {
      final eye = context.cameraPosition;
      _value.setValues(eye.x, eye.y, eye.z, 1);
    } else if (w.abs() > 1e-9 * length) {
      _value.setValues(x / w, y / w, z / w, 1);
    } else {
      // Depth grows along (x, y, z): the viewer is the other way.
      x = -x / length;
      y = -y / length;
      z = -z / length;
      _value.setValues(x, y, z, 0);
    }
    shader.setVector4('BarrierLook.viewer', _value);
  }
}
