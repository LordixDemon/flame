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

  /// The outlines of a honeycomb: one pointy-topped hexagon per motif and
  /// per row, every other row shifted by half a motif.
  hexagons,

  /// A cage: a bar up the middle of each motif and a rung across each row's
  /// boundary.
  grid,
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
/// [topColor], [heightFalloff], [fadeStart], [fadeEnd], [footGlow]), may
/// have a glowing top edge ([topEdgeStrength]) and a body that covers what
/// is behind it ([fillOpacity]), and its near side, the side whose outside
/// faces the viewer, is thinner still ([nearSideFade]), so that it never
/// hides what stands inside it. [appear] raises it from its foot and lowers
/// it back; [heightScale] sets how tall it stands. A slow [pattern] of motifs
/// travels along it, in a band above the foot; it glints where it is seen
/// edge-on ([glintStrength]); [impact] sends rings of light across it from a
/// point, with a flash around that point and, when [wobbleAmplitude] is set,
/// a wave of the surface itself; [pulse] lights the whole wall up and lets it
/// fall back; [setNearPoint] makes it glow where something comes close.
///
/// Every new setting is off (or neutral) by default: a material built with
/// the defaults draws what it drew before they existed.
///
/// Advance [time] every frame: the pattern, the twinkle of its motifs, the
/// noise, the flicker, the impacts and the pulse follow it.
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
/// with an alpha of its brightest channel (or of its fill).
///
/// It writes display colors, like the other materials besides
/// `SpatialMaterial`: in an HDR scene target nothing is clamped, so an
/// [intensity] above `1` and stacked impacts go above white and bloom; in an
/// 8-bit target they clip, unless [preserveHue] is set.
///
/// Every barrier is one draw (its mesh has one surface), and one more while
/// [reactionInFront] shows a reaction. The appear factor, the pattern, the
/// impacts, the pulse and the near points belong to the material, so give
/// each barrier that rises and is hit on its own its own material. Each
/// instance's color tints the wall and its alpha scales its light
/// (`MeshComponent.color`).
///
/// Not available on the web: there are no WebGPU shaders for it.
/// {@endtemplate}
class BarrierMaterial({
  /// The color at the foot of the wall; its alpha scales the light there.
  Color footColor = const Color(0xFFFFB45A),

  /// The color at the top of the wall; its alpha scales the light there.
  Color topColor = const Color(0x4DFFF2D6),

  /// A multiplier of all the light of the wall. Above `1` the bright parts
  /// go above white, which an HDR scene target keeps (and bloom picks up).
  var double intensity = 0.8,

  /// Whether the output keeps its hue where it would go above white: the
  /// color is scaled down where its brightest channel passes `0.8`, so that
  /// it reaches `1` smoothly instead of clipping channel by channel (which
  /// turns a bright warm or cold wall white). `false` by default. It also
  /// keeps the wall at or below white in an HDR scene target, so it does not
  /// bloom there.
  var bool preserveHue = false,

  /// How tall the wall stands, as a scale of the height its mesh was built
  /// with: `1` (the default) as built, `0.5` half as tall, `1.3` taller, `0`
  /// or below not drawn at all. It scales the mesh along its own y axis
  /// about `y = 0` (the foot of a `BarrierMesh` wall) in the vertex stage,
  /// so a game can raise, lower or breathe the wall without rebuilding the
  /// mesh, independently of [appear]; the profile, the top edge and the
  /// motifs follow the wall's height.
  var double heightScale = 1,

  /// How fast the light thins out up the wall: it is multiplied by
  /// `(1 - u) ^ heightFalloff`, `u` running from `0` at [fadeStart] to `1`
  /// at [fadeEnd] (from the foot to the top by default). Below `1` the light
  /// holds and drops near the end of the fade, above `1` it drops soon and
  /// tails off.
  var double heightFalloff = 1.8,

  /// The fraction of the wall's height up to which the light stays full,
  /// `0` by default (the fade starts at the foot).
  var double fadeStart = 0,

  /// The fraction of the wall's height where the light has faded out, `1`
  /// by default (at the top). Above it only the fill, the top edge and the
  /// reactions show.
  var double fadeEnd = 1,

  /// The strength of a thin bright line along the foot.
  var double footGlow = 0.7,

  /// The color of the glowing top edge; its alpha scales it.
  Color topEdgeColor = const Color(0xFFFFFFFF),

  /// The strength of a glowing line along the top of the wall, its upper
  /// boundary, whatever the fade below it: `0` (the default) for none.
  var double topEdgeStrength = 0,

  /// The width of the top edge, a fraction of the wall's height.
  var double topEdgeWidth = 0.04,

  /// How far the wall has risen from its foot, from `0` (not drawn at all)
  /// to `1` (all of it). Animate it to raise and lower the wall.
  var double appear = 1,

  /// The softness of the rising front, as a fraction of the wall's height.
  var double appearSoftness = 0.15,

  /// The color of the body fill; its alpha scales [fillOpacity].
  Color fillColor = const Color(0xFFFFB45A),

  /// The opacity of a body of [fillColor] that fills the wall whatever its
  /// pattern, from `0` (the default: none) through a faint veil to `1`
  /// (opaque). With [RenderState.premultipliedAlphaBlend] or
  /// [RenderState.alphaBlend] it covers what is behind the wall in that
  /// proportion; with [RenderState.additive], which keeps what is behind,
  /// its color is only added. It is thinned on the near side like the rest
  /// of the wall.
  var double fillOpacity = 0,

  /// How much the fill follows the fade of the light, from `0` (the
  /// default: even up the whole wall) to `1` (as the light).
  var double fillFade = 0,

  /// The motif repeated along the wall.
  var BarrierPattern pattern = BarrierPattern.chevrons,

  /// The number of motifs per scene unit along the wall; see
  /// [fitPatternTo].
  var double patternScale = 2.5,

  /// The number of rows of motifs in the band ([patternHeight]), `1` by
  /// default; every other row is shifted by half a motif.
  var int patternRows = 1,

  /// The thickness of the motifs' lines, a multiplier: `1` by default.
  var double patternLineWidth = 1,

  /// How fast the pattern travels along the wall, in scene units per second
  /// (negative values travel the other way).
  var double patternSpeed = 0.3,

  /// How fast the rows of motifs rise up the band, in rows per second (`0`,
  /// the default: they stay; negative values sink). Rising motifs fade in at
  /// the foot of the band and out at its top.
  var double patternRiseSpeed = 0,

  /// The brightness of the motifs.
  var double patternStrength = 0.55,

  /// The top of the band of the wall the motifs fill, as a fraction of its
  /// height from the foot.
  var double patternHeight = 0.45,

  /// The color of the motifs, or `null` (the default) for the foot color
  /// lightened by a third towards white.
  Color? patternColor,

  /// How deeply the motifs twinkle, from `0` (steady) to `1` (each going
  /// dark in turn); `0.25` by default.
  var double patternTwinkle = 0.25,

  /// How fast the motifs twinkle, in radians per second; `1.7` by default.
  var double patternTwinkleSpeed = 1.7,

  /// The length of the wall's closed loop, in scene units along it, or `0`
  /// for a wall that is not closed; see [fitPatternTo].
  var double patternLoopLength = 0,

  /// The strength of a value noise that breaks up the light and the fill of
  /// the wall so that a dense wall is not flat: `0` (the default) for none,
  /// `1` for patches from dark to twice as bright.
  var double noiseStrength = 0,

  /// The size of the noise: cells per scene unit, along the wall and up it.
  var double noiseScale = 3,

  /// How fast the noise rises up the wall, in scene units per second.
  var double noiseSpeed = 0.3,

  /// How deep a flicker of the whole wall's light goes: `0` (the default)
  /// for none, `1` for down to dark. The impacts do not flicker.
  var double flickerStrength = 0,

  /// How fast the wall flickers, in changes per second.
  var double flickerSpeed = 6,

  /// How much the near side of the wall, the side whose outside faces the
  /// viewer, is thinned out, from `0` (not at all) to `1` (only its impacts
  /// show): the far side shows behind what stands inside, the near side does
  /// not veil it. The wall's normals must point out of the enclosed area, as
  /// those of `BarrierMesh` do.
  var double nearSideFade = 0.7,

  /// How much the side of the wall whose inside faces the viewer is thinned
  /// out, from `0` (the default: not at all) to `1`: the far side of a
  /// closed wall seen from outside, every side seen from inside. Set it
  /// instead of [nearSideFade] for a viewer inside the wall, or with it to
  /// show less of the far side through the near side.
  var double farSideFade = 0,

  /// Over how much of the facing (the cosine between the normal and the
  /// direction towards the viewer) the near and far sides thin out: `0.45`
  /// by default, lower for a sharper turn between thinned and full.
  var double sideFadeSoftness = 0.45,

  /// The strength of the glint where the wall is seen edge-on.
  var double glintStrength = 0.35,

  /// How narrow that glint is: higher values keep it closer to the edges.
  var double glintPower = 4,

  /// The color of an [impact] given no color.
  Color impactColor = const Color(0xFFFFFFFF),

  /// The number of impacts shown at once, from `1` to [maxImpactSlots]: a new
  /// one replaces the oldest when all are in use. [maxImpacts] (`4`) by
  /// default.
  var int impactSlots = BarrierMaterial.maxImpacts,

  /// How fast an impact's ring spreads, in scene units per second.
  var double impactRingSpeed = 2.5,

  /// The width of an impact's ring, in scene units.
  var double impactRingWidth = 0.07,

  /// How long an impact lasts, in seconds.
  var double impactDuration = 0.9,

  /// The radius of the flash around an impact's point, in scene units.
  var double impactFlashRadius = 0.3,

  /// The number of rings each impact sends, from `1` (the default) to `4`,
  /// [impactRingInterval] apart, each `0.7` times as bright as the one
  /// before.
  var int impactRingCount = 1,

  /// The seconds between the rings of an impact.
  var double impactRingInterval = 0.15,

  /// The brightness of the rings, `1` by default.
  var double impactRingStrength = 1,

  /// The distance from the point hit at which the rings have faded out, in
  /// scene units; they start fading at 60 % of it. `0` (the default) for no
  /// limit but the impact's duration.
  var double impactRingReach = 0,

  /// The brightness of the flash around an impact's point, `0.8` by default.
  var double impactFlashStrength = 0.8,

  /// How long the flash lasts, a fraction of [impactDuration]: a third by
  /// default.
  var double impactFlashDuration = 1 / 3,

  /// How far the surface moves along its normal around an impact, in scene
  /// units: `0` (the default) for no wobble. A damped wave spreads from the
  /// point hit at `wobbleFrequency * wobbleWavelength` units per second and
  /// dies out with time ([wobbleDecay]), distance ([wobbleRadius]) and the
  /// impact's duration. It moves vertices, so the wall needs rows and columns
  /// a fraction of [wobbleWavelength] apart (`BarrierMesh` takes
  /// `heightSegments` and `maxSegmentLength`); it also tilts the normals, so
  /// the glint and the near-side fade follow it, and shades the light
  /// ([wobbleShading]).
  var double wobbleAmplitude = 0,

  /// How many times a second the wobbling surface swings.
  var double wobbleFrequency = 5,

  /// The distance between the wobble's crests, in scene units.
  var double wobbleWavelength = 0.6,

  /// How fast the wobble dies out, per second: its amplitude is multiplied
  /// by `exp(-wobbleDecay * age)`.
  var double wobbleDecay = 3,

  /// The distance from the point hit at which the wobble has fallen to
  /// `1 / e` of its amplitude, in scene units.
  var double wobbleRadius = 1.5,

  /// How much the wobble brightens the wall where it pushes it out and
  /// darkens it where it pulls it in, from `0` (not at all); `0.5` by
  /// default.
  var double wobbleShading = 0.5,

  /// The color of a [pulse] given no color.
  Color pulseColor = const Color(0xFFFFFFFF),

  /// The strength of a [pulse] given none.
  var double pulseStrength = 1,

  /// The length of a [pulse] given none, in seconds.
  var double pulseDuration = 0.6,

  /// The share of a pulse spent lighting up, the rest falling back: `0.15`
  /// by default.
  var double pulseAttack = 0.15,

  /// The color of a near point given no color.
  Color proximityColor = const Color(0xFFFFFFFF),

  /// The distance from a near point at which it starts to light the wall,
  /// in scene units: the glow grows as `(1 - distance / radius)²` towards
  /// the point.
  var double proximityRadius = 0.6,

  /// The brightness of the glow of the near points.
  var double proximityStrength = 1,

  /// How much the near points brighten the motifs around them: the motifs
  /// are multiplied by `1 + proximityPatternBoost * nearness`.
  var double proximityPatternBoost = 1.5,

  /// How strongly the reaction (the impacts and the glow of the near points)
  /// shows over what stands in front of the wall, from `0` (the default:
  /// hidden by it, as the rest of the wall) to `1` (as bright as where
  /// nothing is in front).
  ///
  /// Above `0`, a `BarrierMesh` draws its surface a second time while a
  /// reaction shows ([drawsReactionInFront]), with [reactionInFrontMaterial]:
  /// the same shaders drawing the reaction only, depth tested with
  /// [CompareFunction.greater], so that it lands only on the pixels where
  /// something in front of the wall hid it, and adds nothing where the wall
  /// was drawn. A mesh of another class draws that second surface itself.
  var double reactionInFront = 0,
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
    this.footColor = footColor;
    this.topColor = topColor;
    this.topEdgeColor = topEdgeColor;
    this.fillColor = fillColor;
    this.patternColor = patternColor;
    this.impactColor = impactColor;
    this.pulseColor = pulseColor;
    this.proximityColor = proximityColor;
  }

  static const String _bundle =
      'packages/flame_3d/assets/shaders/barrier_material.shaderbundle';

  /// The shaders of every option: see [usesFullShader].
  static const String _fullBundle =
      'packages/flame_3d/assets/shaders/barrier_material_full.shaderbundle';

  late final Shader _fullVertexShader = VertexShader.fromAsset(
    _fullBundle,
    slots: const [RenderContext3D.cameraMatricesBlock, 'BarrierShape'],
  );
  late final Shader _fullFragmentShader = FragmentShader.fromAsset(
    _fullBundle,
    slots: const ['BarrierLook'],
  );

  /// Whether the wall is drawn with its full shaders this frame rather than
  /// its lean ones: whether one of the options the lean shaders leave out is
  /// on.
  ///
  /// The lean shaders draw what the barrier drew before its options existed
  /// (one row of the first four patterns, one ring per impact and at most
  /// [maxImpacts] impacts, the near side thinned) plus the [pulse] and the
  /// near points, at the cost they had. The full ones are used while any of
  /// these is on: a pattern that spans cells ([BarrierPattern.hexagons],
  /// [BarrierPattern.grid]), [patternRows] other than `1`,
  /// [patternRiseSpeed], [fadeStart] or [fadeEnd] off their ends, a top edge,
  /// a fill, noise, a flicker, [farSideFade], [preserveHue], more than one
  /// ring or a reach, more than [maxImpacts] slots, or a wobble. They cost
  /// about twice as much per pixel on a desktop GPU, the reaction in front
  /// always uses them, and the first frame that needs them creates their
  /// pipeline.
  bool get usesFullShader =>
      pattern.index > BarrierPattern.dashes.index ||
      patternRows != 1 ||
      patternRiseSpeed != 0 ||
      fadeStart != 0 ||
      fadeEnd != 1 ||
      (topEdgeStrength > 0 && topEdgeWidth > 0) ||
      fillOpacity > 0 ||
      noiseStrength > 0 ||
      flickerStrength > 0 ||
      farSideFade > 0 ||
      preserveHue ||
      impactRingCount > 1 ||
      impactRingReach > 0 ||
      impactSlots > maxImpacts ||
      wobbleAmplitude > 0;

  @override
  Shader get fragmentShader =>
      usesFullShader ? _fullFragmentShader : super.fragmentShader;

  @override
  Shader vertexShaderFor(VertexLayout layout) =>
      usesFullShader ? _fullVertexShader : vertexShader;

  /// The number of impact slots a barrier has by default ([impactSlots]): a
  /// new impact replaces the oldest when all are in use.
  static const int maxImpacts = 4;

  /// The most impacts a barrier can show at once ([impactSlots]).
  static const int maxImpactSlots = 8;

  /// The most near points a barrier shows at once ([setNearPoint]).
  static const int maxNearPoints = 4;

  /// The most rings an impact sends ([impactRingCount]).
  static const int maxImpactRings = 4;

  /// The number of motifs after which the pattern of a wall that is not
  /// closed repeats.
  static const int openWallPeriod = 256;

  /// The time, in seconds, the pattern and the impacts follow: advance it
  /// every frame.
  double time = 0;

  // r, g, b, a of each color, by the indices below.
  final Float64List _colors = Float64List(8 * 4);
  static const int _foot = 0;
  static const int _top = 1;
  static const int _topEdge = 2;
  static const int _fill = 3;
  static const int _patternColor = 4;
  static const int _impactColor = 5;
  static const int _pulseColor = 6;
  static const int _proximityColor = 7;
  bool _hasPatternColor = false;

  /// The color at the foot of the wall; its alpha scales the light there.
  Color get footColor => _readColor(_foot);
  set footColor(Color value) => _writeColor(_foot, value);

  /// The color at the top of the wall; its alpha scales the light there.
  Color get topColor => _readColor(_top);
  set topColor(Color value) => _writeColor(_top, value);

  /// The color of the glowing top edge; its alpha scales it.
  Color get topEdgeColor => _readColor(_topEdge);
  set topEdgeColor(Color value) => _writeColor(_topEdge, value);

  /// The color of the body fill; its alpha scales [fillOpacity].
  Color get fillColor => _readColor(_fill);
  set fillColor(Color value) => _writeColor(_fill, value);

  /// The color of the motifs, or `null` for the foot color lightened by a
  /// third towards white.
  Color? get patternColor =>
      _hasPatternColor ? _readColor(_patternColor) : null;
  set patternColor(Color? value) {
    _hasPatternColor = value != null;
    if (value != null) {
      _writeColor(_patternColor, value);
    }
  }

  /// The color of an [impact] given no color.
  Color get impactColor => _readColor(_impactColor);
  set impactColor(Color value) => _writeColor(_impactColor, value);

  /// The color of a [pulse] given no color.
  Color get pulseColor => _readColor(_pulseColor);
  set pulseColor(Color value) => _writeColor(_pulseColor, value);

  /// The color of a near point given no color.
  Color get proximityColor => _readColor(_proximityColor);
  set proximityColor(Color value) => _writeColor(_proximityColor, value);

  Color _readColor(int index) {
    final o = index * 4;
    return Color.from(
      alpha: _colors[o + 3],
      red: _colors[o],
      green: _colors[o + 1],
      blue: _colors[o + 2],
    );
  }

  void _writeColor(int index, Color color) {
    final o = index * 4;
    _colors
      ..[o] = color.r
      ..[o + 1] = color.g
      ..[o + 2] = color.b
      ..[o + 3] = color.a;
  }

  // x, y, z, start time, r, g, b, strength per impact slot.
  final Float64List _impacts = Float64List(maxImpactSlots * 8);
  // x, y, z, age, r, g, b, strength of the active impacts, oldest slot
  // first, as written to the shaders.
  final Float64List _packedImpacts = Float64List(maxImpactSlots * 8);
  // x, y, z, strength, r, g, b, and 1 when the color is the default.
  final Float64List _nearPoints = Float64List(maxNearPoints * 8);
  final Vector4 _value = Vector4.zero();
  final Matrix4 _inverse = Matrix4.zero();

  double _pulseStart = 0;
  double _pulseFrom = 0;
  double _pulsePeak = 0;
  double _pulseLength = 0;
  final Float64List _pulseRgb = Float64List(3);

  _BarrierReactionMaterial? _reactionMaterial;

  static const List<String> _positionKeys = [
    'BarrierLook.impactPositions[0]',
    'BarrierLook.impactPositions[1]',
    'BarrierLook.impactPositions[2]',
    'BarrierLook.impactPositions[3]',
    'BarrierLook.impactPositions[4]',
    'BarrierLook.impactPositions[5]',
    'BarrierLook.impactPositions[6]',
    'BarrierLook.impactPositions[7]',
  ];
  static const List<String> _colorKeys = [
    'BarrierLook.impactColors[0]',
    'BarrierLook.impactColors[1]',
    'BarrierLook.impactColors[2]',
    'BarrierLook.impactColors[3]',
    'BarrierLook.impactColors[4]',
    'BarrierLook.impactColors[5]',
    'BarrierLook.impactColors[6]',
    'BarrierLook.impactColors[7]',
  ];
  static const List<String> _shapePositionKeys = [
    'BarrierShape.impactPositions[0]',
    'BarrierShape.impactPositions[1]',
    'BarrierShape.impactPositions[2]',
    'BarrierShape.impactPositions[3]',
    'BarrierShape.impactPositions[4]',
    'BarrierShape.impactPositions[5]',
    'BarrierShape.impactPositions[6]',
    'BarrierShape.impactPositions[7]',
  ];
  static const List<String> _nearPositionKeys = [
    'BarrierLook.nearPositions[0]',
    'BarrierLook.nearPositions[1]',
    'BarrierLook.nearPositions[2]',
    'BarrierLook.nearPositions[3]',
  ];
  static const List<String> _nearColorKeys = [
    'BarrierLook.nearColors[0]',
    'BarrierLook.nearColors[1]',
    'BarrierLook.nearColors[2]',
    'BarrierLook.nearColors[3]',
  ];

  /// The number of impact slots in use: [impactSlots] clamped to
  /// `[1, maxImpactSlots]`.
  int get _slots => impactSlots.clamp(1, maxImpactSlots);

  /// Shows an impact at [position] (in world space) at the current [time]:
  /// rings of [color] ([impactColor] when `null`) spreading from it over the
  /// wall and a flash around it, scaled by [strength], for [impactDuration]
  /// seconds.
  ///
  /// It takes a free slot, or the oldest impact's when all [impactSlots] are
  /// in use, and returns the slot's index. It allocates nothing. To hit a
  /// point given on the wall rather than in the world, see
  /// `BarrierMesh.pointOnWall`.
  int impact(Vector3 position, {Color? color, double strength = 1}) {
    var slot = 0;
    var oldest = double.infinity;
    final slots = _slots;
    for (var i = 0; i < slots; i++) {
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
      ..[o + 3] = time;
    if (color == null) {
      const c = _impactColor * 4;
      _impacts
        ..[o + 4] = _colors[c]
        ..[o + 5] = _colors[c + 1]
        ..[o + 6] = _colors[c + 2]
        ..[o + 7] = strength * _colors[c + 3];
    } else {
      _impacts
        ..[o + 4] = color.r
        ..[o + 5] = color.g
        ..[o + 6] = color.b
        ..[o + 7] = strength * color.a;
    }
    return slot;
  }

  /// Whether the impact in [slot] is still showing at the current [time].
  bool isImpactActive(int slot) {
    if (slot < 0 || slot >= _slots) {
      return false;
    }
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
    final slots = _slots;
    for (var i = 0; i < slots; i++) {
      if (isImpactActive(i)) {
        count++;
      }
    }
    return count;
  }

  /// Removes every impact.
  void clearImpacts() => _impacts.fillRange(0, _impacts.length, 0);

  /// Lights the whole wall up with [color] ([pulseColor] when `null`) to
  /// [strength] ([pulseStrength] when `null`) and lets it fall back over
  /// [duration] seconds ([pulseDuration] when `null`): the light rises over
  /// the first [pulseAttack] of it and falls back over the rest. A pulse
  /// started while another shows rises from where that one is.
  ///
  /// It adds `color * value` to the wall's light, more at the foot than at
  /// the top, and raises the fill's cover by `value`; it is thinned on the
  /// near side like the rest of the wall. For a landing, a beat of a
  /// countdown. It allocates nothing.
  void pulse({double? strength, double? duration, Color? color}) {
    _pulseFrom = pulseValue;
    _pulseStart = time;
    _pulsePeak = strength ?? pulseStrength;
    _pulseLength = duration ?? pulseDuration;
    if (color == null) {
      const c = _pulseColor * 4;
      _pulseRgb
        ..[0] = _colors[c] * _colors[c + 3]
        ..[1] = _colors[c + 1] * _colors[c + 3]
        ..[2] = _colors[c + 2] * _colors[c + 3];
    } else {
      _pulseRgb
        ..[0] = color.r * color.a
        ..[1] = color.g * color.a
        ..[2] = color.b * color.a;
    }
  }

  /// The strength of the [pulse] at the current [time], `0` when none shows.
  double get pulseValue {
    final length = _pulseLength;
    final age = time - _pulseStart;
    if (!(length > 0) || age < 0 || age >= length) {
      return 0;
    }
    final attack = pulseAttack.clamp(0.0, 1.0) * length;
    if (age < attack) {
      final t = age / attack;
      return _pulseFrom + (_pulsePeak - _pulseFrom) * (t * t * (3 - 2 * t));
    }
    final rest = length - attack;
    final t = rest > 0 ? (age - attack) / rest : 1.0;
    return _pulsePeak * (1 - t) * (1 - t);
  }

  /// Ends the [pulse] at once.
  void clearPulse() {
    _pulseLength = 0;
    _pulseFrom = 0;
  }

  /// Makes the wall glow where the world point [position] comes close to it,
  /// in [color] ([proximityColor] when `null`), scaled by [strength]: the
  /// glow grows from nothing at [proximityRadius] from the point to its full
  /// strength on it, and brightens the motifs around it
  /// ([proximityPatternBoost]). For something about to hit the wall, a
  /// player walking along it.
  ///
  /// [index] is the point's slot, from `0` to [maxNearPoints] - 1; call it
  /// every frame the point moves. It allocates nothing.
  void setNearPoint(
    int index,
    Vector3 position, {
    double strength = 1,
    Color? color,
  }) {
    RangeError.checkValueInInterval(index, 0, maxNearPoints - 1, 'index');
    final o = index * 8;
    _nearPoints
      ..[o] = position.x
      ..[o + 1] = position.y
      ..[o + 2] = position.z
      ..[o + 3] = strength;
    if (color == null) {
      _nearPoints[o + 7] = 1;
    } else {
      _nearPoints
        ..[o + 4] = color.r * color.a
        ..[o + 5] = color.g * color.a
        ..[o + 6] = color.b * color.a
        ..[o + 7] = 0;
    }
  }

  /// Removes the near point in slot [index].
  void clearNearPoint(int index) {
    RangeError.checkValueInInterval(index, 0, maxNearPoints - 1, 'index');
    _nearPoints[index * 8 + 3] = 0;
  }

  /// Removes every near point.
  void clearNearPoints() => _nearPoints.fillRange(0, _nearPoints.length, 0);

  /// Whether the near point in slot [index] is set, with a strength above
  /// `0`.
  bool isNearPointActive(int index) =>
      index >= 0 && index < maxNearPoints && _nearPoints[index * 8 + 3] > 0;

  /// The number of near points set.
  int get activeNearPointCount {
    var count = 0;
    for (var i = 0; i < maxNearPoints; i++) {
      if (isNearPointActive(i)) {
        count++;
      }
    }
    return count;
  }

  /// Whether a `BarrierMesh` drawn with this material draws its surface a
  /// second time with [reactionInFrontMaterial] this frame: [reactionInFront]
  /// is above `0`, the wall stands ([appear] and [heightScale] above `0`) and
  /// an impact or a near point shows.
  bool get drawsReactionInFront =>
      reactionInFront > 0 &&
      appear > 0 &&
      heightScale > 0 &&
      (activeImpactCount > 0 || activeNearPointCount > 0);

  /// The material that draws the reaction of this barrier over what stands
  /// in front of it (see [reactionInFront]): the same shaders and values,
  /// drawing the impacts and the near points only, scaled by
  /// [reactionInFront], with this material's render state but the depth
  /// test [CompareFunction.greater] and no depth writes, so that it lands
  /// only where something in front of the wall hides it.
  ///
  /// `BarrierMesh` draws it itself. A wall built from another mesh draws its
  /// surface a second time with it while [drawsReactionInFront] holds:
  ///
  /// ```dart
  /// if (barrier.drawsReactionInFront) {
  ///   context.drawSurface(
  ///     surface,
  ///     transform: transform,
  ///     material: barrier.reactionInFrontMaterial,
  ///   );
  /// }
  /// ```
  Material get reactionInFrontMaterial =>
      (_reactionMaterial ??= _BarrierReactionMaterial(this)).._sync();

  /// Sets [patternScale] so that a whole number of motifs of about
  /// [motifLength] scene units fits the closed loop of [loopLength] scene
  /// units (the `length` of a `BarrierMesh`), and [patternLoopLength] to it:
  /// the pattern then has no seam where the loop closes, and motifs that
  /// differ from one to the next ([BarrierPattern.dashes]) stay the same as
  /// they travel across that point. The noise is fitted to the loop the
  /// same way.
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
    _write(this, context as RenderContext3D, 0);
  }

  /// Writes this material's values into the shaders of [target] (this
  /// material, or its reaction material with [reactionScale] above `0`).
  void _write(Material target, RenderContext3D context, double reactionScale) {
    final appear = this.appear.clamp(0.0, 1.0);
    final count = _packImpacts();
    final value = _value;

    // The vertex stage: the height, the wobble and the impacts it moves the
    // surface around.
    final wavelength = math.max(wobbleWavelength, 1e-3);
    final radius = math.max(wobbleRadius, 1e-3);
    final amplitude = wobbleAmplitude > 0 ? wobbleAmplitude : 0.0;
    final vertex = target.vertexShaderFor(BarrierMesh.layout)
      ..setVector4(
        'BarrierShape.params',
        value..setValues(
          appear,
          math.max(heightScale, 0),
          amplitude,
          count.toDouble(),
        ),
      )
      ..setVector4(
        'BarrierShape.wobble',
        value..setValues(
          2 * math.pi / wavelength,
          math.max(wobbleFrequency, 0) * wavelength,
          math.max(wobbleDecay, 0),
          1 / (radius * radius),
        ),
      )
      ..setVector4(
        'BarrierShape.wobbleExtra',
        value..setValues(
          1 / math.max(impactDuration, 1e-3),
          2 / wavelength,
          0,
          0,
        ),
      );
    final p = _packedImpacts;
    for (var i = 0; i < maxImpactSlots; i++) {
      final o = i * 8;
      vertex.setVector4(
        _shapePositionKeys[i],
        value..setValues(p[o], p[o + 1], p[o + 2], p[o + 3]),
      );
    }
    vertex
      ..setVector4(
        'BarrierShape.impactStrengths[0]',
        value..setValues(p[7], p[15], p[23], p[31]),
      )
      ..setVector4(
        'BarrierShape.impactStrengths[1]',
        value..setValues(p[39], p[47], p[55], p[63]),
      );

    final blend = renderState.blend;
    final colors = _colors;
    final shader = target.fragmentShader
      ..setVector4(
        'BarrierLook.footColor',
        value..setValues(colors[0], colors[1], colors[2], colors[3]),
      )
      ..setVector4(
        'BarrierLook.topColor',
        value..setValues(colors[4], colors[5], colors[6], colors[7]),
      )
      ..setVector4(
        'BarrierLook.shape',
        value..setValues(appear, heightFalloff, intensity, footGlow),
      )
      ..setVector4(
        'BarrierLook.pattern',
        value..setValues(
          pattern.index.toDouble(),
          patternScale,
          patternOffset,
          patternStrength,
        ),
      )
      ..setVector4(
        'BarrierLook.patternExtra',
        value..setValues(
          patternHeight,
          patternPeriod,
          patternSpeed < 0 ? -1 : 1,
          _wrap(time * patternTwinkleSpeed, 2 * math.pi),
        ),
      )
      ..setVector4(
        'BarrierLook.glint',
        value..setValues(
          glintStrength,
          glintPower,
          blend == BlendState.alpha ? 0 : 1,
          appearSoftness,
        ),
      )
      ..setVector4(
        'BarrierLook.impactShape',
        value..setValues(
          impactRingSpeed,
          impactRingWidth,
          impactDuration,
          impactFlashRadius,
        ),
      )
      ..setVector4(
        'BarrierLook.extra',
        value..setValues(
          nearSideFade,
          farSideFade,
          sideFadeSoftness,
          count.toDouble(),
        ),
      );
    _writeViewer(context, shader);
    for (var i = 0; i < maxImpactSlots; i++) {
      final o = i * 8;
      shader
        ..setVector4(
          _positionKeys[i],
          value..setValues(p[o], p[o + 1], p[o + 2], p[o + 3]),
        )
        ..setVector4(
          _colorKeys[i],
          value..setValues(p[o + 4], p[o + 5], p[o + 6], p[o + 7]),
        );
    }

    // The fade between two heights.
    final remap = fadeStart != 0 || fadeEnd != 1;
    final flicker = _flicker();
    shader.setVector4(
      'BarrierLook.profile',
      value..setValues(
        fadeStart,
        1 / math.max(fadeEnd - fadeStart, 1e-4),
        remap ? 1 : 0,
        flicker,
      ),
    );
    final topEdgeOn = topEdgeStrength > 0 && topEdgeWidth > 0;
    final edge = colors[_topEdge * 4 + 3] * topEdgeStrength;
    shader
      ..setVector4(
        'BarrierLook.topEdge',
        topEdgeOn
            ? (value..setValues(
                colors[_topEdge * 4] * edge,
                colors[_topEdge * 4 + 1] * edge,
                colors[_topEdge * 4 + 2] * edge,
                1 / topEdgeWidth,
              ))
            : (value..setZero()),
      )
      ..setVector4(
        'BarrierLook.fill',
        value..setValues(
          colors[_fill * 4],
          colors[_fill * 4 + 1],
          colors[_fill * 4 + 2],
          (fillOpacity * colors[_fill * 4 + 3]).clamp(0.0, 1.0),
        ),
      );

    final pulse = pulseValue;
    final wobbleShade = amplitude > 0 && count > 0 && wobbleShading != 0;
    final extras =
        topEdgeOn ||
        pulse > 0 ||
        noiseStrength > 0 ||
        flicker != 1 ||
        wobbleShade;
    shader
      ..setVector4(
        'BarrierLook.mode',
        value..setValues(
          fillFade.clamp(0.0, 1.0),
          preserveHue ? 1 : 0,
          extras ? 1 : 0,
          reactionScale,
        ),
      )
      ..setVector4(
        'BarrierLook.patternStyle',
        value..setValues(
          math.max(patternRows, 1).toDouble(),
          math.max(patternLineWidth, 0),
          patternTwinkle.clamp(0.0, 1.0),
          _wrap(time * patternRiseSpeed, 16),
        ),
      )
      ..setVector4(
        'BarrierLook.patternColor',
        value..setValues(
          colors[_patternColor * 4],
          colors[_patternColor * 4 + 1],
          colors[_patternColor * 4 + 2],
          _hasPatternColor ? 1 : 0,
        ),
      )
      ..setVector4(
        'BarrierLook.patternMore',
        value..setValues(
          patternRiseSpeed != 0 ? 1 : 0,
          proximityPatternBoost,
          wobbleShade ? wobbleShading : 0,
          0,
        ),
      );

    // The noise: fitted to the loop like the pattern.
    var noiseAlong = math.max(noiseScale, 1e-3);
    var noisePeriod = 256.0;
    if (patternLoopLength > 0) {
      noisePeriod = math
          .max(1, (patternLoopLength * noiseAlong).round())
          .toDouble();
      noiseAlong = noisePeriod / patternLoopLength;
    }
    shader
      ..setVector4(
        'BarrierLook.noise',
        value..setValues(
          math.max(noiseStrength, 0),
          noiseAlong,
          math.max(noiseScale, 1e-3),
          _wrap(time * noiseSpeed * noiseScale, 256),
        ),
      )
      ..setVector4(
        'BarrierLook.noiseExtra',
        value..setValues(noisePeriod, 0, 0, 0),
      )
      ..setVector4(
        'BarrierLook.rings',
        value..setValues(
          impactRingCount.clamp(1, maxImpactRings).toDouble(),
          math.max(impactRingInterval, 0),
          impactRingStrength,
          math.max(impactRingReach, 0),
        ),
      )
      ..setVector4(
        'BarrierLook.flash',
        value..setValues(
          impactFlashStrength,
          1 / math.max(impactFlashDuration, 1e-3),
          0,
          0,
        ),
      )
      ..setVector4(
        'BarrierLook.pulse',
        value..setValues(
          _pulseRgb[0] * pulse,
          _pulseRgb[1] * pulse,
          _pulseRgb[2] * pulse,
          pulse,
        ),
      );

    // The near points, the active ones first.
    var near = 0;
    const c = _proximityColor * 4;
    for (var i = 0; i < maxNearPoints; i++) {
      final o = i * 8;
      final strength = _nearPoints[o + 3];
      if (!(strength > 0)) {
        continue;
      }
      final useDefault = _nearPoints[o + 7] > 0.5;
      shader
        ..setVector4(
          _nearPositionKeys[near],
          value..setValues(
            _nearPoints[o],
            _nearPoints[o + 1],
            _nearPoints[o + 2],
            strength,
          ),
        )
        ..setVector4(
          _nearColorKeys[near],
          useDefault
              ? (value..setValues(
                  colors[c] * colors[c + 3],
                  colors[c + 1] * colors[c + 3],
                  colors[c + 2] * colors[c + 3],
                  0,
                ))
              : (value..setValues(
                  _nearPoints[o + 4],
                  _nearPoints[o + 5],
                  _nearPoints[o + 6],
                  0,
                )),
        );
      near++;
    }
    for (var i = near; i < maxNearPoints; i++) {
      shader
        ..setVector4(_nearPositionKeys[i], value..setZero())
        ..setVector4(_nearColorKeys[i], value..setZero());
    }
    shader.setVector4(
      'BarrierLook.proximity',
      value..setValues(
        math.max(proximityRadius, 1e-4),
        proximityStrength,
        near.toDouble(),
        0,
      ),
    );
  }

  /// Packs the active impacts into [_packedImpacts], oldest slot first, with
  /// their age, and clears the rest; returns how many are active.
  int _packImpacts() {
    final packed = _packedImpacts;
    var n = 0;
    final slots = _slots;
    for (var i = 0; i < slots; i++) {
      if (!isImpactActive(i)) {
        continue;
      }
      final o = i * 8;
      final to = n * 8;
      packed
        ..[to] = _impacts[o]
        ..[to + 1] = _impacts[o + 1]
        ..[to + 2] = _impacts[o + 2]
        ..[to + 3] = time - _impacts[o + 3]
        ..[to + 4] = _impacts[o + 4]
        ..[to + 5] = _impacts[o + 5]
        ..[to + 6] = _impacts[o + 6]
        ..[to + 7] = _impacts[o + 7];
      n++;
    }
    for (var i = n; i < maxImpactSlots; i++) {
      final to = i * 8;
      packed
        ..fillRange(to, to + 8, 0)
        ..[to + 3] = -1;
    }
    return n;
  }

  /// The multiplier of the wall's light the flicker sets at the current
  /// [time]: `1` without flicker.
  double _flicker() {
    if (!(flickerStrength > 0)) {
      return 1;
    }
    final x = _wrap(time * flickerSpeed, 4096);
    final i = x.floorToDouble();
    final f = x - i;
    final u = f * f * (3 - 2 * f);
    final a = _hash(i);
    final b = _hash(i + 1);
    final n = a + (b - a) * u;
    return 1 - flickerStrength.clamp(0.0, 1.0) * n;
  }

  static double _hash(double n) {
    final s = math.sin(n * 12.9898 + 78.233) * 43758.5453;
    return s - s.floorToDouble();
  }

  /// [value] wrapped to `[0, period)`, or `0` when it is not finite.
  static double _wrap(double value, double period) {
    final wrapped = value % period;
    return wrapped.isFinite ? wrapped : 0;
  }

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

/// The second material of a [BarrierMaterial] with
/// [BarrierMaterial.reactionInFront]: the same shaders, drawing the reaction
/// only, where something in front of the wall hid it.
class _BarrierReactionMaterial(final BarrierMaterial _source) extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          BarrierMaterial._fullBundle,
          slots: const [RenderContext3D.cameraMatricesBlock, 'BarrierShape'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          BarrierMaterial._fullBundle,
          slots: const ['BarrierLook'],
        ),
      ) {
    castsShadows = false;
  }

  RenderState? _sourceState;

  /// Follows the source's render state and translucent order.
  void _sync() {
    translucentOrder = _source.translucentOrder;
    final state = _source.renderState;
    if (identical(state, _sourceState)) {
      return;
    }
    _sourceState = state;
    renderState = state.copyWith(
      depthTest: true,
      depthCompare: CompareFunction.greater,
      depthWrite: false,
      depthPrepass: false,
      translucent: true,
    );
  }

  @override
  void apply(RenderContext context) {
    _source._write(
      this,
      context as RenderContext3D,
      _source.reactionInFront.clamp(0.0, 1.0),
    );
  }
}
