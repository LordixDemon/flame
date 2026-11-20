import 'dart:ui' show Color;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// {@template barrier_look}
/// Every setting of how a [BarrierMaterial] looks and reacts, as one
/// immutable value: its height profile, its density, its reaction to hits
/// and to things close to it, and its blending.
///
/// A look holds no state: the appear factor, the time, the impacts, the near
/// points and the pulse stay on the material, and so does the length of the
/// wall's loop (`BarrierMaterial.patternLoopLength`), which belongs to the
/// mesh.
///
/// Apply one with [BarrierMaterial.applyLook] (or the
/// [BarrierMaterial.look] setter) and blend two with
/// [BarrierMaterial.applyLookLerp], both without allocating; [lerp] and
/// [copyWith] make new looks. The default look is the material's defaults,
/// and the named presets show the range:
///
/// ```dart
/// final barrier = BarrierMaterial.fromLook(BarrierLook.solidWall);
/// // Noon to dusk, every frame, without allocating:
/// barrier.applyLookLerp(noonLook, duskLook, dusk);
/// ```
///
/// [toJson] and [BarrierLook.fromJson] read and write a look as plain data
/// (colors as `0xAARRGGBB` integers, enums by name); keys left out keep
/// their defaults.
/// {@endtemplate}
@immutable
class const BarrierLook({
  // Light and color.

  /// The color at the foot of the wall; its alpha scales the light there.
  final Color footColor = const Color(0xFFFFB45A),

  /// The color at the top of the wall; its alpha scales the light there.
  final Color topColor = const Color(0x4DFFF2D6),

  /// A multiplier of all the light of the wall.
  final double intensity = 0.8,

  /// Whether the output keeps its hue instead of clipping channel by
  /// channel, see [BarrierMaterial.preserveHue].
  final bool preserveHue = false,

  /// How the wall is blended with what is behind it: [BlendState.additive],
  /// [BlendState.premultipliedAlpha] or [BlendState.alpha].
  final BlendState blend = BlendState.additive,

  // Height.

  /// The scale of the wall's height at run time, see
  /// [BarrierMaterial.heightScale].
  final double heightScale = 1,

  /// How fast the light thins out over the fade, see
  /// [BarrierMaterial.heightFalloff].
  final double heightFalloff = 1.8,

  /// The fraction of the height up to which the light stays full.
  final double fadeStart = 0,

  /// The fraction of the height where the light has faded out.
  final double fadeEnd = 1,

  /// The strength of a thin bright line along the foot.
  final double footGlow = 0.7,

  /// The color of the glowing top edge.
  final Color topEdgeColor = const Color(0xFFFFFFFF),

  /// The strength of the glowing top edge (`0`: none).
  final double topEdgeStrength = 0,

  /// The width of the glowing top edge, a fraction of the height.
  final double topEdgeWidth = 0.04,

  /// The softness of the rising front, a fraction of the height.
  final double appearSoftness = 0.15,

  // Density.

  /// The color of the body fill.
  final Color fillColor = const Color(0xFFFFB45A),

  /// The opacity of the body fill (`0`: none, `1`: opaque).
  final double fillOpacity = 0,

  /// How much the body fill follows the fade of the light, from `0` (even up
  /// the wall) to `1`.
  final double fillFade = 0,

  /// The motif repeated along the wall.
  final BarrierPattern pattern = BarrierPattern.chevrons,

  /// The number of motifs per scene unit along the wall.
  final double patternScale = 2.5,

  /// The number of rows of motifs in the band.
  final int patternRows = 1,

  /// The thickness of the motifs' lines, a multiplier.
  final double patternLineWidth = 1,

  /// The top of the band the motifs fill, a fraction of the height.
  final double patternHeight = 0.45,

  /// The brightness of the motifs.
  final double patternStrength = 0.55,

  /// The color of the motifs, or `null` for the foot color lightened.
  final Color? patternColor,

  /// How fast the motifs travel along the wall, scene units per second.
  final double patternSpeed = 0.3,

  /// How fast the motifs rise up the band, rows per second.
  final double patternRiseSpeed = 0,

  /// How deeply the motifs twinkle, from `0` (steady) to `1`.
  final double patternTwinkle = 0.25,

  /// How fast the motifs twinkle, radians per second.
  final double patternTwinkleSpeed = 1.7,

  /// The strength of the noise that breaks up the light (`0`: none).
  final double noiseStrength = 0,

  /// The size of the noise: cells per scene unit.
  final double noiseScale = 3,

  /// How fast the noise rises up the wall, scene units per second.
  final double noiseSpeed = 0.3,

  /// How deep the flicker of the whole wall goes (`0`: none, `1`: down to
  /// dark).
  final double flickerStrength = 0,

  /// How fast the wall flickers, changes per second.
  final double flickerSpeed = 6,

  /// How much the side whose outside faces the viewer is thinned.
  final double nearSideFade = 0.7,

  /// How much the side whose inside faces the viewer is thinned.
  final double farSideFade = 0,

  /// Over how much of the facing (a cosine) the sides thin.
  final double sideFadeSoftness = 0.45,

  /// The strength of the glint where the wall is seen edge-on.
  final double glintStrength = 0.35,

  /// How narrow that glint is.
  final double glintPower = 4,

  // Reaction.

  /// The color of an impact that is given none.
  final Color impactColor = const Color(0xFFFFFFFF),

  /// The number of impacts shown at once, `1` to
  /// [BarrierMaterial.maxImpactSlots].
  final int impactSlots = BarrierMaterial.maxImpacts,

  /// How long an impact lasts, in seconds.
  final double impactDuration = 0.9,

  /// The number of rings an impact sends, `1` to `4`.
  final int impactRingCount = 1,

  /// The seconds between an impact's rings.
  final double impactRingInterval = 0.15,

  /// How fast the rings spread, scene units per second.
  final double impactRingSpeed = 2.5,

  /// The width of a ring, in scene units.
  final double impactRingWidth = 0.07,

  /// The brightness of the rings.
  final double impactRingStrength = 1,

  /// The distance from the point hit where the rings have faded out, in
  /// scene units (`0`: no limit).
  final double impactRingReach = 0,

  /// The radius of the flash around an impact's point, in scene units.
  final double impactFlashRadius = 0.3,

  /// The brightness of the flash.
  final double impactFlashStrength = 0.8,

  /// How long the flash lasts, a fraction of [impactDuration].
  final double impactFlashDuration = 1 / 3,

  /// How far the surface moves around an impact, in scene units (`0`: no
  /// wobble).
  final double wobbleAmplitude = 0,

  /// How many times a second the surface swings.
  final double wobbleFrequency = 5,

  /// The distance between the wobble's crests, in scene units.
  final double wobbleWavelength = 0.6,

  /// How fast the wobble dies out, per second.
  final double wobbleDecay = 3,

  /// The distance from the point hit at which the wobble has fallen to a
  /// third, in scene units.
  final double wobbleRadius = 1.5,

  /// How much the wobble brightens and darkens the wall where it moves it.
  final double wobbleShading = 0.5,

  /// The color of a pulse that is given none.
  final Color pulseColor = const Color(0xFFFFFFFF),

  /// The strength of a pulse that is given none.
  final double pulseStrength = 1,

  /// The length of a pulse that is given none, in seconds.
  final double pulseDuration = 0.6,

  /// The share of a pulse spent lighting up, the rest falling back.
  final double pulseAttack = 0.15,

  /// The color of a near point that is given none.
  final Color proximityColor = const Color(0xFFFFFFFF),

  /// The distance at which a near point starts to light the wall, in scene
  /// units.
  final double proximityRadius = 0.6,

  /// The brightness of the light of near points.
  final double proximityStrength = 1,

  /// How much near points brighten the motifs around them.
  final double proximityPatternBoost = 1.5,

  /// How strongly the reaction shows over what stands in front of the wall,
  /// from `0` (hidden by it) to `1`.
  final double reactionInFront = 0,
}) {
  /// The material's defaults.
  static const BarrierLook standard = BarrierLook();

  /// A faint, even veil up the whole height with a soft upper edge and a
  /// quiet lattice: a boundary that reads without hiding anything. It lays
  /// over the scene with premultiplied alpha and keeps its hue, so it holds
  /// its color over light water.
  static const BarrierLook softVeil = BarrierLook(
    footColor: Color(0xFF9ADCFF),
    topColor: Color(0x8C9ADCFF),
    intensity: 0.75,
    preserveHue: true,
    blend: BlendState.premultipliedAlpha,
    heightFalloff: 0.8,
    fadeStart: 0.15,
    footGlow: 0.45,
    topEdgeColor: Color(0xFFD8F3FF),
    topEdgeStrength: 0.45,
    topEdgeWidth: 0.05,
    fillColor: Color(0xFF4AA8D8),
    fillOpacity: 0.14,
    fillFade: 0.35,
    pattern: BarrierPattern.diamonds,
    patternScale: 2,
    patternRows: 3,
    patternHeight: 1,
    patternStrength: 0.3,
    patternSpeed: 0.12,
    noiseStrength: 0.3,
    noiseScale: 2,
    noiseSpeed: 0.12,
    nearSideFade: 0.6,
    glintStrength: 0.3,
    impactColor: Color(0xFFE6F7FF),
    impactRingCount: 2,
    impactRingWidth: 0.08,
    impactRingStrength: 1.2,
    impactRingReach: 2.5,
    wobbleAmplitude: 0.03,
    proximityColor: Color(0xFFBDEBFF),
    proximityStrength: 0.6,
    reactionInFront: 0.6,
  );

  /// A tall, dense energy shield: an amber body that hides a good part of
  /// what is behind its far side, a honeycomb over the whole height, a
  /// bright upper edge, a thin near side that keeps the inside in view, and
  /// strong reactions: three rings, a flash, a wobble of the surface, and the
  /// reaction drawn over what stands in front of the wall. Laid over the
  /// scene with premultiplied alpha, keeping its hue.
  static const BarrierLook solidWall = BarrierLook(
    footColor: Color(0xFFFFA640),
    topColor: Color(0x80FFC070),
    intensity: 0.85,
    preserveHue: true,
    blend: BlendState.premultipliedAlpha,
    heightFalloff: 0.9,
    footGlow: 0.8,
    topEdgeColor: Color(0xFFFFE6B0),
    topEdgeStrength: 1,
    topEdgeWidth: 0.035,
    fillColor: Color(0xFFB85A14),
    fillOpacity: 0.38,
    pattern: BarrierPattern.hexagons,
    patternScale: 3,
    patternRows: 4,
    patternHeight: 1,
    patternStrength: 0.8,
    patternColor: Color(0xFFFFE9C2),
    patternSpeed: 0.08,
    noiseStrength: 0.35,
    noiseScale: 2.5,
    noiseSpeed: 0.25,
    nearSideFade: 0.82,
    glintStrength: 0.5,
    impactColor: Color(0xFFFFF6E0),
    impactSlots: 8,
    impactRingCount: 3,
    impactRingInterval: 0.12,
    impactRingSpeed: 2.4,
    impactRingWidth: 0.1,
    impactRingStrength: 2.2,
    impactRingReach: 3,
    impactFlashRadius: 0.35,
    impactFlashStrength: 1.8,
    impactFlashDuration: 0.4,
    wobbleAmplitude: 0.06,
    wobbleFrequency: 4,
    wobbleWavelength: 0.7,
    wobbleDecay: 2.5,
    wobbleShading: 0.6,
    pulseColor: Color(0xFFFFD08A),
    proximityColor: Color(0xFFFFE0A0),
    reactionInFront: 1,
  );

  /// A low glowing fence: a warm band that fades out by half the wall's
  /// height, chevrons along the foot and a bright foot line, laid over the
  /// scene keeping its hue, with rings that show.
  static const BarrierLook lowFence = BarrierLook(
    intensity: 1,
    preserveHue: true,
    blend: BlendState.premultipliedAlpha,
    heightFalloff: 1.4,
    fadeEnd: 0.55,
    footGlow: 1,
    patternHeight: 0.4,
    patternStrength: 0.7,
    impactColor: Color(0xFFFFF0C8),
    impactRingCount: 2,
    impactRingWidth: 0.08,
    impactRingStrength: 1.8,
    impactRingReach: 1.6,
    impactFlashStrength: 1.4,
    reactionInFront: 0.8,
  );

  /// A cold electric cage: a lattice of bars and rungs over the whole
  /// height, a crackle of noise and a flicker, a bright upper edge, sharp
  /// rings; added onto the scene, keeping its hue.
  static const BarrierLook electricCage = BarrierLook(
    footColor: Color(0xFF7FD8FF),
    topColor: Color(0x997FB8FF),
    intensity: 1,
    preserveHue: true,
    heightFalloff: 1,
    fadeStart: 0.2,
    footGlow: 0.6,
    topEdgeColor: Color(0xFFC8F0FF),
    topEdgeStrength: 0.8,
    topEdgeWidth: 0.03,
    fillColor: Color(0xFF3A7BD5),
    fillOpacity: 0.06,
    pattern: BarrierPattern.grid,
    patternScale: 3.5,
    patternRows: 4,
    patternLineWidth: 0.8,
    patternHeight: 1,
    patternStrength: 0.9,
    patternColor: Color(0xFFD6F4FF),
    patternSpeed: 0,
    patternTwinkle: 0.6,
    patternTwinkleSpeed: 9,
    noiseStrength: 0.55,
    noiseScale: 5,
    noiseSpeed: 1.6,
    flickerStrength: 0.25,
    flickerSpeed: 14,
    nearSideFade: 0.75,
    glintStrength: 0.5,
    glintPower: 3,
    impactColor: Color(0xFFE8FAFF),
    impactRingCount: 2,
    impactRingInterval: 0.08,
    impactRingSpeed: 3.5,
    impactRingWidth: 0.05,
    impactRingStrength: 1.6,
    impactFlashRadius: 0.25,
    impactFlashStrength: 1.6,
    impactFlashDuration: 0.25,
    wobbleAmplitude: 0.02,
    wobbleFrequency: 9,
    wobbleWavelength: 0.35,
    wobbleDecay: 6,
    pulseColor: Color(0xFFB8ECFF),
    proximityColor: Color(0xFFCFF4FF),
    proximityStrength: 1.2,
    proximityPatternBoost: 2.5,
    reactionInFront: 0.8,
  );

  /// The named presets, by name.
  static const Map<String, BarrierLook> presets = {
    'standard': standard,
    'softVeil': softVeil,
    'solidWall': solidWall,
    'lowFence': lowFence,
    'electricCage': electricCage,
  };

  /// The look between [a] (at `t = 0`) and [b] (at `t = 1`): numbers and
  /// colors are interpolated linearly (whole numbers rounded), the pattern,
  /// the blend and [preserveHue] switch at `t = 0.5`. A [patternColor] of
  /// `null` blends as the color it stands for (and stays `null` at the end
  /// that has it).
  ///
  /// [BarrierMaterial.applyLookLerp] writes the same values into a material
  /// without making a look.
  // A static method, as Color.lerp and the other lerps of Flutter.
  // ignore: prefer_constructors_over_static_methods
  static BarrierLook lerp(BarrierLook a, BarrierLook b, double t) {
    double d(double x, double y) => lerpLookDouble(x, y, t);
    int i(int x, int y) => lerpLookInt(x, y, t);
    Color c(Color x, Color y) => lerpLookColor(x, y, t);
    final second = t >= 0.5;
    return BarrierLook(
      footColor: c(a.footColor, b.footColor),
      topColor: c(a.topColor, b.topColor),
      intensity: d(a.intensity, b.intensity),
      preserveHue: second ? b.preserveHue : a.preserveHue,
      blend: second ? b.blend : a.blend,
      heightScale: d(a.heightScale, b.heightScale),
      heightFalloff: d(a.heightFalloff, b.heightFalloff),
      fadeStart: d(a.fadeStart, b.fadeStart),
      fadeEnd: d(a.fadeEnd, b.fadeEnd),
      footGlow: d(a.footGlow, b.footGlow),
      topEdgeColor: c(a.topEdgeColor, b.topEdgeColor),
      topEdgeStrength: d(a.topEdgeStrength, b.topEdgeStrength),
      topEdgeWidth: d(a.topEdgeWidth, b.topEdgeWidth),
      appearSoftness: d(a.appearSoftness, b.appearSoftness),
      fillColor: c(a.fillColor, b.fillColor),
      fillOpacity: d(a.fillOpacity, b.fillOpacity),
      fillFade: d(a.fillFade, b.fillFade),
      pattern: second ? b.pattern : a.pattern,
      patternScale: d(a.patternScale, b.patternScale),
      patternRows: i(a.patternRows, b.patternRows),
      patternLineWidth: d(a.patternLineWidth, b.patternLineWidth),
      patternHeight: d(a.patternHeight, b.patternHeight),
      patternStrength: d(a.patternStrength, b.patternStrength),
      patternColor: t <= 0
          ? a.patternColor
          : t >= 1
          ? b.patternColor
          : a.patternColor == null && b.patternColor == null
          ? null
          : c(a.effectivePatternColor, b.effectivePatternColor),
      patternSpeed: d(a.patternSpeed, b.patternSpeed),
      patternRiseSpeed: d(a.patternRiseSpeed, b.patternRiseSpeed),
      patternTwinkle: d(a.patternTwinkle, b.patternTwinkle),
      patternTwinkleSpeed: d(a.patternTwinkleSpeed, b.patternTwinkleSpeed),
      noiseStrength: d(a.noiseStrength, b.noiseStrength),
      noiseScale: d(a.noiseScale, b.noiseScale),
      noiseSpeed: d(a.noiseSpeed, b.noiseSpeed),
      flickerStrength: d(a.flickerStrength, b.flickerStrength),
      flickerSpeed: d(a.flickerSpeed, b.flickerSpeed),
      nearSideFade: d(a.nearSideFade, b.nearSideFade),
      farSideFade: d(a.farSideFade, b.farSideFade),
      sideFadeSoftness: d(a.sideFadeSoftness, b.sideFadeSoftness),
      glintStrength: d(a.glintStrength, b.glintStrength),
      glintPower: d(a.glintPower, b.glintPower),
      impactColor: c(a.impactColor, b.impactColor),
      impactSlots: i(a.impactSlots, b.impactSlots),
      impactDuration: d(a.impactDuration, b.impactDuration),
      impactRingCount: i(a.impactRingCount, b.impactRingCount),
      impactRingInterval: d(a.impactRingInterval, b.impactRingInterval),
      impactRingSpeed: d(a.impactRingSpeed, b.impactRingSpeed),
      impactRingWidth: d(a.impactRingWidth, b.impactRingWidth),
      impactRingStrength: d(a.impactRingStrength, b.impactRingStrength),
      impactRingReach: d(a.impactRingReach, b.impactRingReach),
      impactFlashRadius: d(a.impactFlashRadius, b.impactFlashRadius),
      impactFlashStrength: d(a.impactFlashStrength, b.impactFlashStrength),
      impactFlashDuration: d(a.impactFlashDuration, b.impactFlashDuration),
      wobbleAmplitude: d(a.wobbleAmplitude, b.wobbleAmplitude),
      wobbleFrequency: d(a.wobbleFrequency, b.wobbleFrequency),
      wobbleWavelength: d(a.wobbleWavelength, b.wobbleWavelength),
      wobbleDecay: d(a.wobbleDecay, b.wobbleDecay),
      wobbleRadius: d(a.wobbleRadius, b.wobbleRadius),
      wobbleShading: d(a.wobbleShading, b.wobbleShading),
      pulseColor: c(a.pulseColor, b.pulseColor),
      pulseStrength: d(a.pulseStrength, b.pulseStrength),
      pulseDuration: d(a.pulseDuration, b.pulseDuration),
      pulseAttack: d(a.pulseAttack, b.pulseAttack),
      proximityColor: c(a.proximityColor, b.proximityColor),
      proximityRadius: d(a.proximityRadius, b.proximityRadius),
      proximityStrength: d(a.proximityStrength, b.proximityStrength),
      proximityPatternBoost: d(
        a.proximityPatternBoost,
        b.proximityPatternBoost,
      ),
      reactionInFront: d(a.reactionInFront, b.reactionInFront),
    );
  }

  /// The color of the motifs: [patternColor], or the foot color lightened
  /// as the material draws it when [patternColor] is `null`.
  Color get effectivePatternColor =>
      patternColor ??
      Color.from(
        alpha: 1,
        red: footColor.r * 0.65 + 0.35,
        green: footColor.g * 0.65 + 0.35,
        blue: footColor.b * 0.65 + 0.35,
      );

  /// The value between [a] and [b] at [t], as [lerp] and
  /// [BarrierMaterial.applyLookLerp] compute it.
  @internal
  static double lerpLookDouble(double a, double b, double t) =>
      a * (1 - t) + b * t;

  /// The whole number between [a] and [b] at [t], rounded.
  @internal
  static int lerpLookInt(int a, int b, double t) =>
      (a * (1 - t) + b * t).round();

  /// The channel of a color between [a] and [b] at [t], clamped to `[0, 1]`.
  @internal
  static double lerpLookChannel(double a, double b, double t) =>
      (a * (1 - t) + b * t).clamp(0.0, 1.0);

  /// The color between [a] and [b] at [t], channel by channel.
  @internal
  static Color lerpLookColor(Color a, Color b, double t) => Color.from(
    alpha: lerpLookChannel(a.a, b.a, t),
    red: lerpLookChannel(a.r, b.r, t),
    green: lerpLookChannel(a.g, b.g, t),
    blue: lerpLookChannel(a.b, b.b, t),
  );

  /// A copy of this look with the given settings replaced; pass
  /// `clearPatternColor: true` to set [patternColor] back to `null`.
  BarrierLook copyWith({
    Color? footColor,
    Color? topColor,
    double? intensity,
    bool? preserveHue,
    BlendState? blend,
    double? heightScale,
    double? heightFalloff,
    double? fadeStart,
    double? fadeEnd,
    double? footGlow,
    Color? topEdgeColor,
    double? topEdgeStrength,
    double? topEdgeWidth,
    double? appearSoftness,
    Color? fillColor,
    double? fillOpacity,
    double? fillFade,
    BarrierPattern? pattern,
    double? patternScale,
    int? patternRows,
    double? patternLineWidth,
    double? patternHeight,
    double? patternStrength,
    Color? patternColor,
    bool clearPatternColor = false,
    double? patternSpeed,
    double? patternRiseSpeed,
    double? patternTwinkle,
    double? patternTwinkleSpeed,
    double? noiseStrength,
    double? noiseScale,
    double? noiseSpeed,
    double? flickerStrength,
    double? flickerSpeed,
    double? nearSideFade,
    double? farSideFade,
    double? sideFadeSoftness,
    double? glintStrength,
    double? glintPower,
    Color? impactColor,
    int? impactSlots,
    double? impactDuration,
    int? impactRingCount,
    double? impactRingInterval,
    double? impactRingSpeed,
    double? impactRingWidth,
    double? impactRingStrength,
    double? impactRingReach,
    double? impactFlashRadius,
    double? impactFlashStrength,
    double? impactFlashDuration,
    double? wobbleAmplitude,
    double? wobbleFrequency,
    double? wobbleWavelength,
    double? wobbleDecay,
    double? wobbleRadius,
    double? wobbleShading,
    Color? pulseColor,
    double? pulseStrength,
    double? pulseDuration,
    double? pulseAttack,
    Color? proximityColor,
    double? proximityRadius,
    double? proximityStrength,
    double? proximityPatternBoost,
    double? reactionInFront,
  }) {
    return BarrierLook(
      footColor: footColor ?? this.footColor,
      topColor: topColor ?? this.topColor,
      intensity: intensity ?? this.intensity,
      preserveHue: preserveHue ?? this.preserveHue,
      blend: blend ?? this.blend,
      heightScale: heightScale ?? this.heightScale,
      heightFalloff: heightFalloff ?? this.heightFalloff,
      fadeStart: fadeStart ?? this.fadeStart,
      fadeEnd: fadeEnd ?? this.fadeEnd,
      footGlow: footGlow ?? this.footGlow,
      topEdgeColor: topEdgeColor ?? this.topEdgeColor,
      topEdgeStrength: topEdgeStrength ?? this.topEdgeStrength,
      topEdgeWidth: topEdgeWidth ?? this.topEdgeWidth,
      appearSoftness: appearSoftness ?? this.appearSoftness,
      fillColor: fillColor ?? this.fillColor,
      fillOpacity: fillOpacity ?? this.fillOpacity,
      fillFade: fillFade ?? this.fillFade,
      pattern: pattern ?? this.pattern,
      patternScale: patternScale ?? this.patternScale,
      patternRows: patternRows ?? this.patternRows,
      patternLineWidth: patternLineWidth ?? this.patternLineWidth,
      patternHeight: patternHeight ?? this.patternHeight,
      patternStrength: patternStrength ?? this.patternStrength,
      patternColor: clearPatternColor
          ? null
          : (patternColor ?? this.patternColor),
      patternSpeed: patternSpeed ?? this.patternSpeed,
      patternRiseSpeed: patternRiseSpeed ?? this.patternRiseSpeed,
      patternTwinkle: patternTwinkle ?? this.patternTwinkle,
      patternTwinkleSpeed: patternTwinkleSpeed ?? this.patternTwinkleSpeed,
      noiseStrength: noiseStrength ?? this.noiseStrength,
      noiseScale: noiseScale ?? this.noiseScale,
      noiseSpeed: noiseSpeed ?? this.noiseSpeed,
      flickerStrength: flickerStrength ?? this.flickerStrength,
      flickerSpeed: flickerSpeed ?? this.flickerSpeed,
      nearSideFade: nearSideFade ?? this.nearSideFade,
      farSideFade: farSideFade ?? this.farSideFade,
      sideFadeSoftness: sideFadeSoftness ?? this.sideFadeSoftness,
      glintStrength: glintStrength ?? this.glintStrength,
      glintPower: glintPower ?? this.glintPower,
      impactColor: impactColor ?? this.impactColor,
      impactSlots: impactSlots ?? this.impactSlots,
      impactDuration: impactDuration ?? this.impactDuration,
      impactRingCount: impactRingCount ?? this.impactRingCount,
      impactRingInterval: impactRingInterval ?? this.impactRingInterval,
      impactRingSpeed: impactRingSpeed ?? this.impactRingSpeed,
      impactRingWidth: impactRingWidth ?? this.impactRingWidth,
      impactRingStrength: impactRingStrength ?? this.impactRingStrength,
      impactRingReach: impactRingReach ?? this.impactRingReach,
      impactFlashRadius: impactFlashRadius ?? this.impactFlashRadius,
      impactFlashStrength: impactFlashStrength ?? this.impactFlashStrength,
      impactFlashDuration: impactFlashDuration ?? this.impactFlashDuration,
      wobbleAmplitude: wobbleAmplitude ?? this.wobbleAmplitude,
      wobbleFrequency: wobbleFrequency ?? this.wobbleFrequency,
      wobbleWavelength: wobbleWavelength ?? this.wobbleWavelength,
      wobbleDecay: wobbleDecay ?? this.wobbleDecay,
      wobbleRadius: wobbleRadius ?? this.wobbleRadius,
      wobbleShading: wobbleShading ?? this.wobbleShading,
      pulseColor: pulseColor ?? this.pulseColor,
      pulseStrength: pulseStrength ?? this.pulseStrength,
      pulseDuration: pulseDuration ?? this.pulseDuration,
      pulseAttack: pulseAttack ?? this.pulseAttack,
      proximityColor: proximityColor ?? this.proximityColor,
      proximityRadius: proximityRadius ?? this.proximityRadius,
      proximityStrength: proximityStrength ?? this.proximityStrength,
      proximityPatternBoost:
          proximityPatternBoost ?? this.proximityPatternBoost,
      reactionInFront: reactionInFront ?? this.reactionInFront,
    );
  }

  /// This look as plain data: numbers, booleans, colors as `0xAARRGGBB`
  /// integers and enums by name, under the names of the fields.
  Map<String, Object?> toJson() => {
    'footColor': footColor.toARGB32(),
    'topColor': topColor.toARGB32(),
    'intensity': intensity,
    'preserveHue': preserveHue,
    'blend': blend.name,
    'heightScale': heightScale,
    'heightFalloff': heightFalloff,
    'fadeStart': fadeStart,
    'fadeEnd': fadeEnd,
    'footGlow': footGlow,
    'topEdgeColor': topEdgeColor.toARGB32(),
    'topEdgeStrength': topEdgeStrength,
    'topEdgeWidth': topEdgeWidth,
    'appearSoftness': appearSoftness,
    'fillColor': fillColor.toARGB32(),
    'fillOpacity': fillOpacity,
    'fillFade': fillFade,
    'pattern': pattern.name,
    'patternScale': patternScale,
    'patternRows': patternRows,
    'patternLineWidth': patternLineWidth,
    'patternHeight': patternHeight,
    'patternStrength': patternStrength,
    'patternColor': patternColor?.toARGB32(),
    'patternSpeed': patternSpeed,
    'patternRiseSpeed': patternRiseSpeed,
    'patternTwinkle': patternTwinkle,
    'patternTwinkleSpeed': patternTwinkleSpeed,
    'noiseStrength': noiseStrength,
    'noiseScale': noiseScale,
    'noiseSpeed': noiseSpeed,
    'flickerStrength': flickerStrength,
    'flickerSpeed': flickerSpeed,
    'nearSideFade': nearSideFade,
    'farSideFade': farSideFade,
    'sideFadeSoftness': sideFadeSoftness,
    'glintStrength': glintStrength,
    'glintPower': glintPower,
    'impactColor': impactColor.toARGB32(),
    'impactSlots': impactSlots,
    'impactDuration': impactDuration,
    'impactRingCount': impactRingCount,
    'impactRingInterval': impactRingInterval,
    'impactRingSpeed': impactRingSpeed,
    'impactRingWidth': impactRingWidth,
    'impactRingStrength': impactRingStrength,
    'impactRingReach': impactRingReach,
    'impactFlashRadius': impactFlashRadius,
    'impactFlashStrength': impactFlashStrength,
    'impactFlashDuration': impactFlashDuration,
    'wobbleAmplitude': wobbleAmplitude,
    'wobbleFrequency': wobbleFrequency,
    'wobbleWavelength': wobbleWavelength,
    'wobbleDecay': wobbleDecay,
    'wobbleRadius': wobbleRadius,
    'wobbleShading': wobbleShading,
    'pulseColor': pulseColor.toARGB32(),
    'pulseStrength': pulseStrength,
    'pulseDuration': pulseDuration,
    'pulseAttack': pulseAttack,
    'proximityColor': proximityColor.toARGB32(),
    'proximityRadius': proximityRadius,
    'proximityStrength': proximityStrength,
    'proximityPatternBoost': proximityPatternBoost,
    'reactionInFront': reactionInFront,
  };

  /// The look that [toJson] wrote; keys that are missing keep the defaults
  /// of [BarrierLook]. Throws a [FormatException] for a value of the wrong
  /// type or an unknown enum name.
  factory BarrierLook.fromJson(Map<String, Object?> json) {
    const base = BarrierLook.standard;
    double d(String key, double fallback) => switch (json[key]) {
      null => fallback,
      final num value => value.toDouble(),
      final other => throw FormatException('"$key" is not a number', other),
    };
    int i(String key, int fallback) => switch (json[key]) {
      null => fallback,
      final int value => value,
      final num value when value == value.roundToDouble() => value.toInt(),
      final other => throw FormatException('"$key" is not an int', other),
    };
    Color c(String key, Color fallback) => switch (json[key]) {
      null => fallback,
      final int value => Color(value),
      final other => throw FormatException('"$key" is not a color', other),
    };
    T e<T extends Enum>(String key, List<T> values, T fallback) {
      final name = json[key];
      if (name == null) {
        return fallback;
      }
      for (final value in values) {
        if (value.name == name) {
          return value;
        }
      }
      throw FormatException('"$key" has no value "$name"', name);
    }

    final preserveHue = switch (json['preserveHue']) {
      null => base.preserveHue,
      final bool value => value,
      final other => throw FormatException(
        '"preserveHue" is not a bool',
        other,
      ),
    };
    final patternColor = switch (json['patternColor']) {
      null => null,
      final int value => Color(value),
      final other => throw FormatException(
        '"patternColor" is not a color',
        other,
      ),
    };
    return BarrierLook(
      footColor: c('footColor', base.footColor),
      topColor: c('topColor', base.topColor),
      intensity: d('intensity', base.intensity),
      preserveHue: preserveHue,
      blend: e('blend', BlendState.values, base.blend),
      heightScale: d('heightScale', base.heightScale),
      heightFalloff: d('heightFalloff', base.heightFalloff),
      fadeStart: d('fadeStart', base.fadeStart),
      fadeEnd: d('fadeEnd', base.fadeEnd),
      footGlow: d('footGlow', base.footGlow),
      topEdgeColor: c('topEdgeColor', base.topEdgeColor),
      topEdgeStrength: d('topEdgeStrength', base.topEdgeStrength),
      topEdgeWidth: d('topEdgeWidth', base.topEdgeWidth),
      appearSoftness: d('appearSoftness', base.appearSoftness),
      fillColor: c('fillColor', base.fillColor),
      fillOpacity: d('fillOpacity', base.fillOpacity),
      fillFade: d('fillFade', base.fillFade),
      pattern: e('pattern', BarrierPattern.values, base.pattern),
      patternScale: d('patternScale', base.patternScale),
      patternRows: i('patternRows', base.patternRows),
      patternLineWidth: d('patternLineWidth', base.patternLineWidth),
      patternHeight: d('patternHeight', base.patternHeight),
      patternStrength: d('patternStrength', base.patternStrength),
      patternColor: patternColor,
      patternSpeed: d('patternSpeed', base.patternSpeed),
      patternRiseSpeed: d('patternRiseSpeed', base.patternRiseSpeed),
      patternTwinkle: d('patternTwinkle', base.patternTwinkle),
      patternTwinkleSpeed: d('patternTwinkleSpeed', base.patternTwinkleSpeed),
      noiseStrength: d('noiseStrength', base.noiseStrength),
      noiseScale: d('noiseScale', base.noiseScale),
      noiseSpeed: d('noiseSpeed', base.noiseSpeed),
      flickerStrength: d('flickerStrength', base.flickerStrength),
      flickerSpeed: d('flickerSpeed', base.flickerSpeed),
      nearSideFade: d('nearSideFade', base.nearSideFade),
      farSideFade: d('farSideFade', base.farSideFade),
      sideFadeSoftness: d('sideFadeSoftness', base.sideFadeSoftness),
      glintStrength: d('glintStrength', base.glintStrength),
      glintPower: d('glintPower', base.glintPower),
      impactColor: c('impactColor', base.impactColor),
      impactSlots: i('impactSlots', base.impactSlots),
      impactDuration: d('impactDuration', base.impactDuration),
      impactRingCount: i('impactRingCount', base.impactRingCount),
      impactRingInterval: d('impactRingInterval', base.impactRingInterval),
      impactRingSpeed: d('impactRingSpeed', base.impactRingSpeed),
      impactRingWidth: d('impactRingWidth', base.impactRingWidth),
      impactRingStrength: d('impactRingStrength', base.impactRingStrength),
      impactRingReach: d('impactRingReach', base.impactRingReach),
      impactFlashRadius: d('impactFlashRadius', base.impactFlashRadius),
      impactFlashStrength: d('impactFlashStrength', base.impactFlashStrength),
      impactFlashDuration: d('impactFlashDuration', base.impactFlashDuration),
      wobbleAmplitude: d('wobbleAmplitude', base.wobbleAmplitude),
      wobbleFrequency: d('wobbleFrequency', base.wobbleFrequency),
      wobbleWavelength: d('wobbleWavelength', base.wobbleWavelength),
      wobbleDecay: d('wobbleDecay', base.wobbleDecay),
      wobbleRadius: d('wobbleRadius', base.wobbleRadius),
      wobbleShading: d('wobbleShading', base.wobbleShading),
      pulseColor: c('pulseColor', base.pulseColor),
      pulseStrength: d('pulseStrength', base.pulseStrength),
      pulseDuration: d('pulseDuration', base.pulseDuration),
      pulseAttack: d('pulseAttack', base.pulseAttack),
      proximityColor: c('proximityColor', base.proximityColor),
      proximityRadius: d('proximityRadius', base.proximityRadius),
      proximityStrength: d('proximityStrength', base.proximityStrength),
      proximityPatternBoost: d(
        'proximityPatternBoost',
        base.proximityPatternBoost,
      ),
      reactionInFront: d('reactionInFront', base.reactionInFront),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! BarrierLook) {
      return false;
    }
    final a = _values;
    final b = other._values;
    for (var k = 0; k < a.length; k++) {
      if (a[k] != b[k]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_values);

  @override
  String toString() => 'BarrierLook(${toJson()})';

  /// Every setting, in the order of the fields.
  List<Object?> get _values => [
    footColor,
    topColor,
    intensity,
    preserveHue,
    blend,
    heightScale,
    heightFalloff,
    fadeStart,
    fadeEnd,
    footGlow,
    topEdgeColor,
    topEdgeStrength,
    topEdgeWidth,
    appearSoftness,
    fillColor,
    fillOpacity,
    fillFade,
    pattern,
    patternScale,
    patternRows,
    patternLineWidth,
    patternHeight,
    patternStrength,
    patternColor,
    patternSpeed,
    patternRiseSpeed,
    patternTwinkle,
    patternTwinkleSpeed,
    noiseStrength,
    noiseScale,
    noiseSpeed,
    flickerStrength,
    flickerSpeed,
    nearSideFade,
    farSideFade,
    sideFadeSoftness,
    glintStrength,
    glintPower,
    impactColor,
    impactSlots,
    impactDuration,
    impactRingCount,
    impactRingInterval,
    impactRingSpeed,
    impactRingWidth,
    impactRingStrength,
    impactRingReach,
    impactFlashRadius,
    impactFlashStrength,
    impactFlashDuration,
    wobbleAmplitude,
    wobbleFrequency,
    wobbleWavelength,
    wobbleDecay,
    wobbleRadius,
    wobbleShading,
    pulseColor,
    pulseStrength,
    pulseDuration,
    pulseAttack,
    proximityColor,
    proximityRadius,
    proximityStrength,
    proximityPatternBoost,
    reactionInFront,
  ];
}
