import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

part 'barrier_reaction.dart';
part 'barrier_uniforms.dart';

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
/// Every setting of its look is also held, as one value, by a [BarrierLook]:
/// apply one with [applyLook] and blend two with [applyLookLerp], without
/// allocating. Every new setting is off (or neutral) by default: a material
/// built with the defaults draws what it drew before they existed.
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

  var double _intensity = 0.8,
  var bool _preserveHue = false,
  var double _heightScale = 1,
  var double _heightFalloff = 1.8,
  var double _fadeStart = 0,
  var double _fadeEnd = 1,
  var double _footGlow = 0.7,

  /// The color of the glowing top edge; its alpha scales it.
  Color topEdgeColor = const Color(0xFFFFFFFF),

  var double _topEdgeStrength = 0,
  var double _topEdgeWidth = 0.04,
  var double _appear = 1,
  var double _appearSoftness = 0.15,

  /// The color of the body fill; its alpha scales [fillOpacity].
  Color fillColor = const Color(0xFFFFB45A),

  var double _fillOpacity = 0,
  var double _fillFade = 0,
  var BarrierPattern _pattern = BarrierPattern.chevrons,
  var double _patternScale = 2.5,
  var int _patternRows = 1,
  var double _patternLineWidth = 1,
  var double _patternSpeed = 0.3,
  var double _patternRiseSpeed = 0,
  var double _patternStrength = 0.55,
  var double _patternHeight = 0.45,

  /// The color of the motifs, or `null` (the default) for the foot color
  /// lightened by a third towards white.
  Color? patternColor,

  var double _patternTwinkle = 0.25,
  var double _patternTwinkleSpeed = 1.7,
  var double _patternLoopLength = 0,
  var double _noiseStrength = 0,
  var double _noiseScale = 3,
  var double _noiseSpeed = 0.3,
  var double _flickerStrength = 0,
  var double _flickerSpeed = 6,
  var double _nearSideFade = 0.7,
  var double _farSideFade = 0,
  var double _sideFadeSoftness = 0.45,
  var double _glintStrength = 0.35,
  var double _glintPower = 4,

  /// The color of an [impact] given no color.
  Color impactColor = const Color(0xFFFFFFFF),

  var int _impactSlots = BarrierMaterial.maxImpacts,
  var double _impactRingSpeed = 2.5,
  var double _impactRingWidth = 0.07,
  var double _impactDuration = 0.9,
  var double _impactFlashRadius = 0.3,
  var int _impactRingCount = 1,
  var double _impactRingInterval = 0.15,
  var double _impactRingStrength = 1,
  var double _impactRingReach = 0,
  var double _impactFlashStrength = 0.8,
  var double _impactFlashDuration = 1 / 3,
  var double _wobbleAmplitude = 0,
  var double _wobbleFrequency = 5,
  var double _wobbleWavelength = 0.6,
  var double _wobbleDecay = 3,
  var double _wobbleRadius = 1.5,
  var double _wobbleShading = 0.5,

  /// The color of a [pulse] given no color.
  Color pulseColor = const Color(0xFFFFFFFF),

  var double _pulseStrength = 1,
  var double _pulseDuration = 0.6,
  var double _pulseAttack = 0.15,

  /// The color of a near point given no color.
  Color proximityColor = const Color(0xFFFFFFFF),

  var double _proximityRadius = 0.6,
  var double _proximityStrength = 1,
  var double _proximityPatternBoost = 1.5,
  var double _reactionInFront = 0,
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
    setInitialState(renderState: renderState, castsShadows: false);
    this.footColor = footColor;
    this.topColor = topColor;
    this.topEdgeColor = topEdgeColor;
    this.fillColor = fillColor;
    this.patternColor = patternColor;
    this.impactColor = impactColor;
    this.pulseColor = pulseColor;
    this.proximityColor = proximityColor;
  }

  /// A multiplier of all the light of the wall. Above `1` the bright parts
  /// go above white, which an HDR scene target keeps (and bloom picks up).
  double get intensity => _intensity;
  set intensity(double value) => _intensity = noteChange(_intensity, value);

  /// Whether the output keeps its hue where it would go above white: the
  /// color is scaled down where its brightest channel passes `0.8`, so that
  /// it reaches `1` smoothly instead of clipping channel by channel (which
  /// turns a bright warm or cold wall white). `false` by default. It also
  /// keeps the wall at or below white in an HDR scene target, so it does not
  /// bloom there.
  bool get preserveHue => _preserveHue;
  set preserveHue(bool value) => _preserveHue = noteChange(_preserveHue, value);

  /// How tall the wall stands, as a scale of the height its mesh was built
  /// with: `1` (the default) as built, `0.5` half as tall, `1.3` taller, `0`
  /// or below not drawn at all. It scales the mesh along its own y axis
  /// about `y = 0` (the foot of a `BarrierMesh` wall) in the vertex stage,
  /// so a game can raise, lower or breathe the wall without rebuilding the
  /// mesh, independently of [appear]; the profile, the top edge and the
  /// motifs follow the wall's height.
  double get heightScale => _heightScale;
  set heightScale(double value) =>
      _heightScale = noteChange(_heightScale, value);

  /// How fast the light thins out up the wall: it is multiplied by
  /// `(1 - u) ^ heightFalloff`, `u` running from `0` at [fadeStart] to `1`
  /// at [fadeEnd] (from the foot to the top by default). Below `1` the light
  /// holds and drops near the end of the fade, above `1` it drops soon and
  /// tails off.
  double get heightFalloff => _heightFalloff;
  set heightFalloff(double value) =>
      _heightFalloff = noteChange(_heightFalloff, value);

  /// The fraction of the wall's height up to which the light stays full,
  /// `0` by default (the fade starts at the foot).
  double get fadeStart => _fadeStart;
  set fadeStart(double value) => _fadeStart = noteChange(_fadeStart, value);

  /// The fraction of the wall's height where the light has faded out, `1`
  /// by default (at the top). Above it only the fill, the top edge and the
  /// reactions show.
  double get fadeEnd => _fadeEnd;
  set fadeEnd(double value) => _fadeEnd = noteChange(_fadeEnd, value);

  /// The strength of a thin bright line along the foot.
  double get footGlow => _footGlow;
  set footGlow(double value) => _footGlow = noteChange(_footGlow, value);

  /// The strength of a glowing line along the top of the wall, its upper
  /// boundary, whatever the fade below it: `0` (the default) for none.
  double get topEdgeStrength => _topEdgeStrength;
  set topEdgeStrength(double value) =>
      _topEdgeStrength = noteChange(_topEdgeStrength, value);

  /// The width of the top edge, a fraction of the wall's height.
  double get topEdgeWidth => _topEdgeWidth;
  set topEdgeWidth(double value) =>
      _topEdgeWidth = noteChange(_topEdgeWidth, value);

  /// How far the wall has risen from its foot, from `0` (not drawn at all)
  /// to `1` (all of it). Animate it to raise and lower the wall.
  double get appear => _appear;
  set appear(double value) => _appear = noteChange(_appear, value);

  /// The softness of the rising front, as a fraction of the wall's height.
  double get appearSoftness => _appearSoftness;
  set appearSoftness(double value) =>
      _appearSoftness = noteChange(_appearSoftness, value);

  /// The opacity of a body of [fillColor] that fills the wall whatever its
  /// pattern, from `0` (the default: none) through a faint veil to `1`
  /// (opaque). With [RenderState.premultipliedAlphaBlend] or
  /// [RenderState.alphaBlend] it covers what is behind the wall in that
  /// proportion; with [RenderState.additive], which keeps what is behind,
  /// its color is only added. It is thinned on the near side like the rest
  /// of the wall.
  double get fillOpacity => _fillOpacity;
  set fillOpacity(double value) =>
      _fillOpacity = noteChange(_fillOpacity, value);

  /// How much the fill follows the fade of the light, from `0` (the
  /// default: even up the whole wall) to `1` (as the light).
  double get fillFade => _fillFade;
  set fillFade(double value) => _fillFade = noteChange(_fillFade, value);

  /// The motif repeated along the wall.
  BarrierPattern get pattern => _pattern;
  set pattern(BarrierPattern value) => _pattern = noteChange(_pattern, value);

  /// The number of motifs per scene unit along the wall; see
  /// [fitPatternTo].
  double get patternScale => _patternScale;
  set patternScale(double value) =>
      _patternScale = noteChange(_patternScale, value);

  /// The number of rows of motifs in the band ([patternHeight]), `1` by
  /// default; every other row is shifted by half a motif.
  int get patternRows => _patternRows;
  set patternRows(int value) => _patternRows = noteChange(_patternRows, value);

  /// The thickness of the motifs' lines, a multiplier: `1` by default.
  double get patternLineWidth => _patternLineWidth;
  set patternLineWidth(double value) =>
      _patternLineWidth = noteChange(_patternLineWidth, value);

  /// How fast the pattern travels along the wall, in scene units per second
  /// (negative values travel the other way).
  double get patternSpeed => _patternSpeed;
  set patternSpeed(double value) =>
      _patternSpeed = noteChange(_patternSpeed, value);

  /// How fast the rows of motifs rise up the band, in rows per second (`0`,
  /// the default: they stay; negative values sink). Rising motifs fade in at
  /// the foot of the band and out at its top.
  double get patternRiseSpeed => _patternRiseSpeed;
  set patternRiseSpeed(double value) =>
      _patternRiseSpeed = noteChange(_patternRiseSpeed, value);

  /// The brightness of the motifs.
  double get patternStrength => _patternStrength;
  set patternStrength(double value) =>
      _patternStrength = noteChange(_patternStrength, value);

  /// The top of the band of the wall the motifs fill, as a fraction of its
  /// height from the foot.
  double get patternHeight => _patternHeight;
  set patternHeight(double value) =>
      _patternHeight = noteChange(_patternHeight, value);

  /// How deeply the motifs twinkle, from `0` (steady) to `1` (each going
  /// dark in turn); `0.25` by default.
  double get patternTwinkle => _patternTwinkle;
  set patternTwinkle(double value) =>
      _patternTwinkle = noteChange(_patternTwinkle, value);

  /// How fast the motifs twinkle, in radians per second; `1.7` by default.
  double get patternTwinkleSpeed => _patternTwinkleSpeed;
  set patternTwinkleSpeed(double value) =>
      _patternTwinkleSpeed = noteChange(_patternTwinkleSpeed, value);

  /// The length of the wall's closed loop, in scene units along it, or `0`
  /// for a wall that is not closed; see [fitPatternTo].
  double get patternLoopLength => _patternLoopLength;
  set patternLoopLength(double value) =>
      _patternLoopLength = noteChange(_patternLoopLength, value);

  /// The strength of a value noise that breaks up the light and the fill of
  /// the wall so that a dense wall is not flat: `0` (the default) for none,
  /// `1` for patches from dark to twice as bright.
  double get noiseStrength => _noiseStrength;
  set noiseStrength(double value) =>
      _noiseStrength = noteChange(_noiseStrength, value);

  /// The size of the noise: cells per scene unit, along the wall and up it.
  double get noiseScale => _noiseScale;
  set noiseScale(double value) => _noiseScale = noteChange(_noiseScale, value);

  /// How fast the noise rises up the wall, in scene units per second.
  double get noiseSpeed => _noiseSpeed;
  set noiseSpeed(double value) => _noiseSpeed = noteChange(_noiseSpeed, value);

  /// How deep a flicker of the whole wall's light goes: `0` (the default)
  /// for none, `1` for down to dark. The impacts do not flicker.
  double get flickerStrength => _flickerStrength;
  set flickerStrength(double value) =>
      _flickerStrength = noteChange(_flickerStrength, value);

  /// How fast the wall flickers, in changes per second.
  double get flickerSpeed => _flickerSpeed;
  set flickerSpeed(double value) =>
      _flickerSpeed = noteChange(_flickerSpeed, value);

  /// How much the near side of the wall, the side whose outside faces the
  /// viewer, is thinned out, from `0` (not at all) to `1` (only its impacts
  /// show): the far side shows behind what stands inside, the near side does
  /// not veil it. The wall's normals must point out of the enclosed area, as
  /// those of `BarrierMesh` do.
  double get nearSideFade => _nearSideFade;
  set nearSideFade(double value) =>
      _nearSideFade = noteChange(_nearSideFade, value);

  /// How much the side of the wall whose inside faces the viewer is thinned
  /// out, from `0` (the default: not at all) to `1`: the far side of a
  /// closed wall seen from outside, every side seen from inside. Set it
  /// instead of [nearSideFade] for a viewer inside the wall, or with it to
  /// show less of the far side through the near side.
  double get farSideFade => _farSideFade;
  set farSideFade(double value) =>
      _farSideFade = noteChange(_farSideFade, value);

  /// Over how much of the facing (the cosine between the normal and the
  /// direction towards the viewer) the near and far sides thin out: `0.45`
  /// by default, lower for a sharper turn between thinned and full.
  double get sideFadeSoftness => _sideFadeSoftness;
  set sideFadeSoftness(double value) =>
      _sideFadeSoftness = noteChange(_sideFadeSoftness, value);

  /// The strength of the glint where the wall is seen edge-on.
  double get glintStrength => _glintStrength;
  set glintStrength(double value) =>
      _glintStrength = noteChange(_glintStrength, value);

  /// How narrow that glint is: higher values keep it closer to the edges.
  double get glintPower => _glintPower;
  set glintPower(double value) => _glintPower = noteChange(_glintPower, value);

  /// The number of impacts shown at once, from `1` to [maxImpactSlots]: a new
  /// one replaces the oldest when all are in use. [maxImpacts] (`4`) by
  /// default.
  int get impactSlots => _impactSlots;
  set impactSlots(int value) => _impactSlots = noteChange(_impactSlots, value);

  /// How fast an impact's ring spreads, in scene units per second.
  double get impactRingSpeed => _impactRingSpeed;
  set impactRingSpeed(double value) =>
      _impactRingSpeed = noteChange(_impactRingSpeed, value);

  /// The width of an impact's ring, in scene units.
  double get impactRingWidth => _impactRingWidth;
  set impactRingWidth(double value) =>
      _impactRingWidth = noteChange(_impactRingWidth, value);

  /// How long an impact lasts, in seconds.
  double get impactDuration => _impactDuration;
  set impactDuration(double value) =>
      _impactDuration = noteChange(_impactDuration, value);

  /// The radius of the flash around an impact's point, in scene units.
  double get impactFlashRadius => _impactFlashRadius;
  set impactFlashRadius(double value) =>
      _impactFlashRadius = noteChange(_impactFlashRadius, value);

  /// The number of rings each impact sends, from `1` (the default) to `4`,
  /// [impactRingInterval] apart, each `0.7` times as bright as the one
  /// before.
  int get impactRingCount => _impactRingCount;
  set impactRingCount(int value) =>
      _impactRingCount = noteChange(_impactRingCount, value);

  /// The seconds between the rings of an impact.
  double get impactRingInterval => _impactRingInterval;
  set impactRingInterval(double value) =>
      _impactRingInterval = noteChange(_impactRingInterval, value);

  /// The brightness of the rings, `1` by default.
  double get impactRingStrength => _impactRingStrength;
  set impactRingStrength(double value) =>
      _impactRingStrength = noteChange(_impactRingStrength, value);

  /// The distance from the point hit at which the rings have faded out, in
  /// scene units; they start fading at 60 % of it. `0` (the default) for no
  /// limit but the impact's duration.
  double get impactRingReach => _impactRingReach;
  set impactRingReach(double value) =>
      _impactRingReach = noteChange(_impactRingReach, value);

  /// The brightness of the flash around an impact's point, `0.8` by default.
  double get impactFlashStrength => _impactFlashStrength;
  set impactFlashStrength(double value) =>
      _impactFlashStrength = noteChange(_impactFlashStrength, value);

  /// How long the flash lasts, a fraction of [impactDuration]: a third by
  /// default.
  double get impactFlashDuration => _impactFlashDuration;
  set impactFlashDuration(double value) =>
      _impactFlashDuration = noteChange(_impactFlashDuration, value);

  /// How far the surface moves along its normal around an impact, in scene
  /// units: `0` (the default) for no wobble. A damped wave spreads from the
  /// point hit at `wobbleFrequency * wobbleWavelength` units per second and
  /// dies out with time ([wobbleDecay]), distance ([wobbleRadius]) and the
  /// impact's duration. It moves vertices, so the wall needs rows and columns
  /// a fraction of [wobbleWavelength] apart (`BarrierMesh` takes
  /// `heightSegments` and `maxSegmentLength`); it also tilts the normals, so
  /// the glint and the near-side fade follow it, and shades the light
  /// ([wobbleShading]).
  double get wobbleAmplitude => _wobbleAmplitude;
  set wobbleAmplitude(double value) =>
      _wobbleAmplitude = noteChange(_wobbleAmplitude, value);

  /// How many times a second the wobbling surface swings.
  double get wobbleFrequency => _wobbleFrequency;
  set wobbleFrequency(double value) =>
      _wobbleFrequency = noteChange(_wobbleFrequency, value);

  /// The distance between the wobble's crests, in scene units.
  double get wobbleWavelength => _wobbleWavelength;
  set wobbleWavelength(double value) =>
      _wobbleWavelength = noteChange(_wobbleWavelength, value);

  /// How fast the wobble dies out, per second: its amplitude is multiplied
  /// by `exp(-wobbleDecay * age)`.
  double get wobbleDecay => _wobbleDecay;
  set wobbleDecay(double value) =>
      _wobbleDecay = noteChange(_wobbleDecay, value);

  /// The distance from the point hit at which the wobble has fallen to
  /// `1 / e` of its amplitude, in scene units.
  double get wobbleRadius => _wobbleRadius;
  set wobbleRadius(double value) =>
      _wobbleRadius = noteChange(_wobbleRadius, value);

  /// How much the wobble brightens the wall where it pushes it out and
  /// darkens it where it pulls it in, from `0` (not at all); `0.5` by
  /// default.
  double get wobbleShading => _wobbleShading;
  set wobbleShading(double value) =>
      _wobbleShading = noteChange(_wobbleShading, value);

  /// The strength of a [pulse] given none.
  double get pulseStrength => _pulseStrength;
  set pulseStrength(double value) =>
      _pulseStrength = noteChange(_pulseStrength, value);

  /// The length of a [pulse] given none, in seconds.
  double get pulseDuration => _pulseDuration;
  set pulseDuration(double value) =>
      _pulseDuration = noteChange(_pulseDuration, value);

  /// The share of a pulse spent lighting up, the rest falling back: `0.15`
  /// by default.
  double get pulseAttack => _pulseAttack;
  set pulseAttack(double value) =>
      _pulseAttack = noteChange(_pulseAttack, value);

  /// The distance from a near point at which it starts to light the wall,
  /// in scene units: the glow grows as `(1 - distance / radius)²` towards
  /// the point.
  double get proximityRadius => _proximityRadius;
  set proximityRadius(double value) =>
      _proximityRadius = noteChange(_proximityRadius, value);

  /// The brightness of the glow of the near points.
  double get proximityStrength => _proximityStrength;
  set proximityStrength(double value) =>
      _proximityStrength = noteChange(_proximityStrength, value);

  /// How much the near points brighten the motifs around them: the motifs
  /// are multiplied by `1 + proximityPatternBoost * nearness`.
  double get proximityPatternBoost => _proximityPatternBoost;
  set proximityPatternBoost(double value) =>
      _proximityPatternBoost = noteChange(_proximityPatternBoost, value);

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
  double get reactionInFront => _reactionInFront;
  set reactionInFront(double value) =>
      _reactionInFront = noteChange(_reactionInFront, value);

  /// A material with the settings of [look], raised to [appear].
  factory BarrierMaterial.fromLook(BarrierLook look, {double appear = 1}) {
    return BarrierMaterial(appear: appear)..applyLook(look);
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
  double get time => _time;
  set time(double value) => _time = noteTime(_time, value);
  double _time = 0;

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
    if (_hasPatternColor != (value != null)) {
      _hasPatternColor = value != null;
      markChanged();
    }
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
    _writeChannels(index, color.r, color.g, color.b, color.a);
  }

  /// Writes the channels of the color at [index], reporting a change when
  /// one of them differs.
  void _writeChannels(int index, double r, double g, double b, double a) {
    final o = index * 4;
    final colors = _colors;
    if (colors[o] == r &&
        colors[o + 1] == g &&
        colors[o + 2] == b &&
        colors[o + 3] == a) {
      return;
    }
    colors
      ..[o] = r
      ..[o + 1] = g
      ..[o + 2] = b
      ..[o + 3] = a;
    markChanged();
  }

  // x, y, z, start time, r, g, b, strength per impact slot.
  final Float64List _impacts = Float64List(maxImpactSlots * 8);
  // x, y, z, age, r, g, b, strength of the active impacts, oldest slot
  // first, as written to the shaders.
  final Float64List _packedImpacts = Float64List(maxImpactSlots * 8);
  // x, y, z, strength, r, g, b, and 1 when the color is the default.
  final Float64List _nearPoints = Float64List(maxNearPoints * 8);

  double _pulseStart = 0;
  double _pulseFrom = 0;
  double _pulsePeak = 0;
  double _pulseLength = 0;
  final Float64List _pulseRgb = Float64List(3);

  _BarrierReactionMaterial? _reactionMaterial;

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
    markChanged();
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
  void clearImpacts() => _clear(_impacts);

  /// Zeroes [values], reporting a change when one of them was not `0`.
  void _clear(Float64List values) {
    for (var i = 0; i < values.length; i++) {
      if (values[i] != 0) {
        values.fillRange(0, values.length, 0);
        markChanged();
        return;
      }
    }
  }

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
    markChanged();
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
    if (_pulseLength == 0 && _pulseFrom == 0) {
      return;
    }
    _pulseLength = 0;
    _pulseFrom = 0;
    markChanged();
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
    final points = _nearPoints;
    var changed = _setValue(points, o, position.x);
    changed = _setValue(points, o + 1, position.y) || changed;
    changed = _setValue(points, o + 2, position.z) || changed;
    changed = _setValue(points, o + 3, strength) || changed;
    if (color == null) {
      changed = _setValue(points, o + 7, 1) || changed;
    } else {
      changed = _setValue(points, o + 4, color.r * color.a) || changed;
      changed = _setValue(points, o + 5, color.g * color.a) || changed;
      changed = _setValue(points, o + 6, color.b * color.a) || changed;
      changed = _setValue(points, o + 7, 0) || changed;
    }
    if (changed) {
      markChanged();
    }
  }

  /// Writes [value] at [index] of [values], returning whether it changed.
  static bool _setValue(Float64List values, int index, double value) {
    if (values[index] == value) {
      return false;
    }
    values[index] = value;
    return true;
  }

  /// Removes the near point in slot [index].
  void clearNearPoint(int index) {
    RangeError.checkValueInInterval(index, 0, maxNearPoints - 1, 'index');
    if (_setValue(_nearPoints, index * 8 + 3, 0)) {
      markChanged();
    }
  }

  /// Removes every near point.
  void clearNearPoints() => _clear(_nearPoints);

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

  /// The settings of this material's look, as a value (it allocates one).
  BarrierLook get look => BarrierLook(
    footColor: footColor,
    topColor: topColor,
    intensity: intensity,
    preserveHue: preserveHue,
    blend: renderState.blend,
    heightScale: heightScale,
    heightFalloff: heightFalloff,
    fadeStart: fadeStart,
    fadeEnd: fadeEnd,
    footGlow: footGlow,
    topEdgeColor: topEdgeColor,
    topEdgeStrength: topEdgeStrength,
    topEdgeWidth: topEdgeWidth,
    appearSoftness: appearSoftness,
    fillColor: fillColor,
    fillOpacity: fillOpacity,
    fillFade: fillFade,
    pattern: pattern,
    patternScale: patternScale,
    patternRows: patternRows,
    patternLineWidth: patternLineWidth,
    patternHeight: patternHeight,
    patternStrength: patternStrength,
    patternColor: patternColor,
    patternSpeed: patternSpeed,
    patternRiseSpeed: patternRiseSpeed,
    patternTwinkle: patternTwinkle,
    patternTwinkleSpeed: patternTwinkleSpeed,
    noiseStrength: noiseStrength,
    noiseScale: noiseScale,
    noiseSpeed: noiseSpeed,
    flickerStrength: flickerStrength,
    flickerSpeed: flickerSpeed,
    nearSideFade: nearSideFade,
    farSideFade: farSideFade,
    sideFadeSoftness: sideFadeSoftness,
    glintStrength: glintStrength,
    glintPower: glintPower,
    impactColor: impactColor,
    impactSlots: impactSlots,
    impactDuration: impactDuration,
    impactRingCount: impactRingCount,
    impactRingInterval: impactRingInterval,
    impactRingSpeed: impactRingSpeed,
    impactRingWidth: impactRingWidth,
    impactRingStrength: impactRingStrength,
    impactRingReach: impactRingReach,
    impactFlashRadius: impactFlashRadius,
    impactFlashStrength: impactFlashStrength,
    impactFlashDuration: impactFlashDuration,
    wobbleAmplitude: wobbleAmplitude,
    wobbleFrequency: wobbleFrequency,
    wobbleWavelength: wobbleWavelength,
    wobbleDecay: wobbleDecay,
    wobbleRadius: wobbleRadius,
    wobbleShading: wobbleShading,
    pulseColor: pulseColor,
    pulseStrength: pulseStrength,
    pulseDuration: pulseDuration,
    pulseAttack: pulseAttack,
    proximityColor: proximityColor,
    proximityRadius: proximityRadius,
    proximityStrength: proximityStrength,
    proximityPatternBoost: proximityPatternBoost,
    reactionInFront: reactionInFront,
  );

  /// Applies [value], see [applyLook].
  set look(BarrierLook value) => applyLook(value);

  /// Takes every setting of [look]: its colors and numbers, and its blend
  /// (the [renderState] keeps its other fields). The impacts, the near
  /// points, the pulse, [appear], [time] and [patternLoopLength] are kept;
  /// on a closed loop the look's [patternScale] is rounded to a whole number
  /// of motifs, as [fitPatternTo] does.
  ///
  /// It allocates nothing (unless the blend changes from a custom render
  /// state).
  void applyLook(BarrierLook look) => applyLookLerp(look, look, 0);

  /// Takes the settings between [a] (at `t = 0`) and [b] (at `t = 1`), as
  /// [BarrierLook.lerp] computes them, without making a look: numbers and
  /// colors interpolated linearly (whole numbers rounded), the pattern, the
  /// blend and [preserveHue] switching at `t = 0.5`. Call it every frame to
  /// animate a look (noon to dusk, calm to alarm); it allocates nothing
  /// (unless the blend changes from a custom render state).
  void applyLookLerp(BarrierLook a, BarrierLook b, double t) {
    double d(double x, double y) => BarrierLook.lerpLookDouble(x, y, t);
    int i(int x, int y) => BarrierLook.lerpLookInt(x, y, t);
    final second = t >= 0.5;
    _lerpColor(_foot, a.footColor, b.footColor, t);
    _lerpColor(_top, a.topColor, b.topColor, t);
    intensity = d(a.intensity, b.intensity);
    preserveHue = second ? b.preserveHue : a.preserveHue;
    heightScale = d(a.heightScale, b.heightScale);
    heightFalloff = d(a.heightFalloff, b.heightFalloff);
    fadeStart = d(a.fadeStart, b.fadeStart);
    fadeEnd = d(a.fadeEnd, b.fadeEnd);
    footGlow = d(a.footGlow, b.footGlow);
    _lerpColor(_topEdge, a.topEdgeColor, b.topEdgeColor, t);
    topEdgeStrength = d(a.topEdgeStrength, b.topEdgeStrength);
    topEdgeWidth = d(a.topEdgeWidth, b.topEdgeWidth);
    appearSoftness = d(a.appearSoftness, b.appearSoftness);
    _lerpColor(_fill, a.fillColor, b.fillColor, t);
    fillOpacity = d(a.fillOpacity, b.fillOpacity);
    fillFade = d(a.fillFade, b.fillFade);
    pattern = second ? b.pattern : a.pattern;
    patternScale = _fitToLoop(d(a.patternScale, b.patternScale));
    patternRows = i(a.patternRows, b.patternRows);
    patternLineWidth = d(a.patternLineWidth, b.patternLineWidth);
    patternHeight = d(a.patternHeight, b.patternHeight);
    patternStrength = d(a.patternStrength, b.patternStrength);
    final patternEnd = t <= 0 ? a : (t >= 1 ? b : null);
    if (patternEnd != null) {
      patternColor = patternEnd.patternColor;
    } else if (a.patternColor == null && b.patternColor == null) {
      patternColor = null;
    } else {
      if (!_hasPatternColor) {
        _hasPatternColor = true;
        markChanged();
      }
      _lerpColor(
        _patternColor,
        a.effectivePatternColor,
        b.effectivePatternColor,
        t,
      );
    }
    patternSpeed = d(a.patternSpeed, b.patternSpeed);
    patternRiseSpeed = d(a.patternRiseSpeed, b.patternRiseSpeed);
    patternTwinkle = d(a.patternTwinkle, b.patternTwinkle);
    patternTwinkleSpeed = d(a.patternTwinkleSpeed, b.patternTwinkleSpeed);
    noiseStrength = d(a.noiseStrength, b.noiseStrength);
    noiseScale = d(a.noiseScale, b.noiseScale);
    noiseSpeed = d(a.noiseSpeed, b.noiseSpeed);
    flickerStrength = d(a.flickerStrength, b.flickerStrength);
    flickerSpeed = d(a.flickerSpeed, b.flickerSpeed);
    nearSideFade = d(a.nearSideFade, b.nearSideFade);
    farSideFade = d(a.farSideFade, b.farSideFade);
    sideFadeSoftness = d(a.sideFadeSoftness, b.sideFadeSoftness);
    glintStrength = d(a.glintStrength, b.glintStrength);
    glintPower = d(a.glintPower, b.glintPower);
    _lerpColor(_impactColor, a.impactColor, b.impactColor, t);
    impactSlots = i(a.impactSlots, b.impactSlots);
    impactDuration = d(a.impactDuration, b.impactDuration);
    impactRingCount = i(a.impactRingCount, b.impactRingCount);
    impactRingInterval = d(a.impactRingInterval, b.impactRingInterval);
    impactRingSpeed = d(a.impactRingSpeed, b.impactRingSpeed);
    impactRingWidth = d(a.impactRingWidth, b.impactRingWidth);
    impactRingStrength = d(a.impactRingStrength, b.impactRingStrength);
    impactRingReach = d(a.impactRingReach, b.impactRingReach);
    impactFlashRadius = d(a.impactFlashRadius, b.impactFlashRadius);
    impactFlashStrength = d(a.impactFlashStrength, b.impactFlashStrength);
    impactFlashDuration = d(a.impactFlashDuration, b.impactFlashDuration);
    wobbleAmplitude = d(a.wobbleAmplitude, b.wobbleAmplitude);
    wobbleFrequency = d(a.wobbleFrequency, b.wobbleFrequency);
    wobbleWavelength = d(a.wobbleWavelength, b.wobbleWavelength);
    wobbleDecay = d(a.wobbleDecay, b.wobbleDecay);
    wobbleRadius = d(a.wobbleRadius, b.wobbleRadius);
    wobbleShading = d(a.wobbleShading, b.wobbleShading);
    _lerpColor(_pulseColor, a.pulseColor, b.pulseColor, t);
    pulseStrength = d(a.pulseStrength, b.pulseStrength);
    pulseDuration = d(a.pulseDuration, b.pulseDuration);
    pulseAttack = d(a.pulseAttack, b.pulseAttack);
    _lerpColor(_proximityColor, a.proximityColor, b.proximityColor, t);
    proximityRadius = d(a.proximityRadius, b.proximityRadius);
    proximityStrength = d(a.proximityStrength, b.proximityStrength);
    proximityPatternBoost = d(
      a.proximityPatternBoost,
      b.proximityPatternBoost,
    );
    reactionInFront = d(a.reactionInFront, b.reactionInFront);
    _setBlend(second ? b.blend : a.blend);
  }

  void _lerpColor(int index, Color a, Color b, double t) {
    _writeChannels(
      index,
      BarrierLook.lerpLookChannel(a.r, b.r, t),
      BarrierLook.lerpLookChannel(a.g, b.g, t),
      BarrierLook.lerpLookChannel(a.b, b.b, t),
      BarrierLook.lerpLookChannel(a.a, b.a, t),
    );
  }

  /// [scale] rounded to a whole number of motifs on the closed loop of
  /// [patternLoopLength], or [scale] on a wall that is not closed.
  double _fitToLoop(double scale) {
    final loop = patternLoopLength;
    if (!(loop > 0) || !(scale > 0)) {
      return scale;
    }
    final count = math.max(1, (loop * scale).round());
    return count / loop;
  }

  void _setBlend(BlendState blend) {
    final state = renderState;
    if (state.blend == blend) {
      return;
    }
    const standard = [
      RenderState.additive,
      RenderState.premultipliedAlphaBlend,
      RenderState.alphaBlend,
    ];
    if (standard.contains(state)) {
      for (final candidate in standard) {
        if (candidate.blend == blend) {
          renderState = candidate;
          return;
        }
      }
    }
    renderState = state.copyWith(blend: blend);
  }

  int _appliedVersion = -1;
  Shader? _appliedVert;
  int _appliedVertGen = -1;
  Shader? _appliedFrag;
  int _appliedFragGen = -1;
  RenderContext? _appliedContext;
  int _appliedCameraPass = -1;

  @override
  bool get hasPassStableFragmentShader => runtimeType == BarrierMaterial;

  @override
  bool get cachesApply => runtimeType == BarrierMaterial;

  @override
  void invalidateApplyCache() {
    _appliedVersion = -1;
  }

  @override
  bool isApplyCacheValid(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    return _appliedVersion == version &&
        identical(_appliedVert, vertexShader) &&
        _appliedVertGen == vertexShader.generation &&
        identical(_appliedFrag, fragmentShader) &&
        _appliedFragGen == fragmentShader.generation &&
        identical(_appliedContext, context) &&
        context is RenderContext3D &&
        _appliedCameraPass == context.cameraPass;
  }

  @override
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    _appliedVersion = version;
    _appliedVert = vertexShader;
    _appliedVertGen = vertexShader.generation;
    _appliedFrag = fragmentShader;
    _appliedFragGen = fragmentShader.generation;
    _appliedContext = context;
    if (context is RenderContext3D) {
      _appliedCameraPass = context.cameraPass;
    }
  }

  @override
  void apply(RenderContext context) {
    _write(this, context as RenderContext3D, 0);
  }
}
