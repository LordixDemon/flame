import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

/// {@template shadow_settings}
/// How a [DirectionalLight], [SpotLight], or [PointLight] casts shadows: the
/// resolution of its shadow map (or tile in the unified `ShadowAtlas3D`), the
/// part of the scene the map covers, how shadows look, and the biases that keep
/// surfaces from shadowing themselves.
///
/// Supports up to `4` Cascaded Shadow Maps (`cascades: 1..4`) on
/// [DirectionalLight] with smooth cascade boundary blending, simultaneous
/// perspective shadows on up to `2` [SpotLight]s, and omnidirectional
/// Dual-Paraboloid (`+Z`/`-Z`) shadows on [PointLight].
/// {@endtemplate}
class ShadowSettings({
  /// The width and height of the shadow map (or base tile), in texels: more is
  /// sharper and costs more memory and fill rate.
  int resolution = 1024,

  /// The part of the scene the shadow map covers.
  var ShadowFit fit = ShadowFit.view,

  /// The region that receives shadows, in world space, instead of the bounds
  /// of the whole scene: see [ShadowFit]. Casters outside it still cast
  /// shadows into it.
  var Aabb3? bounds,

  /// With [ShadowFit.view], the farthest distance from the camera, along the
  /// direction it looks in, that receives shadows; `null` for no limit
  /// besides the bounds of the scene. Limiting it sharpens the shadows of a
  /// perspective camera that sees far.
  var double? maxDistance,

  /// How much of the light the shadows take away, from `0` (shadows are
  /// invisible) to `1` (as much as [color] says).
  var double strength = 1.0,

  /// The color the shadowed light is multiplied by at full [strength]: black
  /// (the default) takes it all away, and a color lets some of each channel
  /// through, which tints the shadows with it rather than darkening them.
  var Color color = const Color(0xFF000000),

  /// How soft the edges of the shadows are: the radius of the filter, in
  /// texels, from `0` (a 2 by 2 bilinear filter, 4 samples) to `3`. The
  /// default `1` blends a 3 by 3 texel area (16 samples).
  int softness = 1,

  /// How far a receiving surface is pushed towards the light before it is
  /// compared with the shadow map, in texels of the map.
  var double depthBias = 1.0,

  /// How far, beyond what the filter of [softness] needs, a receiving
  /// surface is pushed along its normal before it is compared with the
  /// shadow map, in texels of the map.
  var double normalBias = 0.5,

  /// How depths are stored in the shadow map.
  var ShadowMapEncoding encoding = ShadowMapEncoding.auto,

  /// Whether the shadow map is kept aligned with its texels as the camera
  /// moves, so that the edges of the shadows stay still instead of
  /// shimmering.
  var bool stabilize = true,

  /// Whether the shadow pass is skipped on frames where the light direction,
  /// shadow settings, fitted shadow projection, and shadow-casting scene
  /// geometry have not changed since the previous shadow map was rendered.
  var bool cacheWhenStatic = false,

  /// Number of directional shadow cascades (`1`..`4`).
  int cascades = 1,

  /// Fraction `(0..1)` of `maxDistance` (or scene span) covered by Cascade `0`
  /// when [cascades] is `2` (or used as the initial split ratio for `3..4`
  /// cascades when [cascadeSplits] is `null`).
  var double cascadeSplitRatio = 0.28,

  /// Optional explicit monotonically increasing split fractions in `(0..1]` for
  /// `cascades >= 2` (e.g. `[0.12, 0.32, 0.62, 1.0]` for 4 cascades).
  var List<double>? cascadeSplits,

  /// Fraction `[0..0.35]` of each cascade's UV border across which adjacent
  /// cascades smoothly cross-fade (`0` disables cross-cascade blending).
  var double cascadeBlendRange = 0.1,
}) {
  /// {@macro shadow_settings}
  this {
    this.resolution = resolution;
    this.softness = softness;
    this.cascades = cascades;
  }

  /// The width and height of the shadow map, in texels, from 16 to 8192.
  int get resolution => _resolution;
  set resolution(int value) {
    if (value < 16 || value > 8192) {
      throw ArgumentError.value(value, 'resolution', 'Must be 16 to 8192');
    }
    _resolution = value;
  }

  int _resolution = 1024;

  /// The radius of the filter that softens the edges of the shadows, in
  /// texels, from `0` to [maxSoftness].
  int get softness => _softness;
  set softness(int value) {
    if (value < 0 || value > maxSoftness) {
      throw ArgumentError.value(value, 'softness', 'Must be 0 to $maxSoftness');
    }
    _softness = value;
  }

  int _softness = 1;

  /// Number of directional shadow cascades (`1` to `4`).
  int get cascades => _cascades;
  set cascades(int value) {
    if (value < 1 || value > maxCascades) {
      throw ArgumentError.value(
        value,
        'cascades',
        'Must be 1 to $maxCascades',
      );
    }
    _cascades = value;
  }

  int _cascades = 1;

  /// Maximum number of directional shadow cascades supported.
  static const int maxCascades = 4;

  /// The largest [softness].
  static const int maxSoftness = 3;
}

/// The part of a scene a [ShadowSettings]'s shadow map covers.
enum ShadowFit() {
  /// The part of the region the camera sees: the shadows are as sharp as the
  /// map allows, and the map follows the camera, aligned with its texels so
  /// that the shadows do not shimmer.
  view,

  /// The whole region, whatever the camera sees: the map only changes when
  /// the region does, which suits small scenes seen whole, and scenes whose
  /// camera moves a lot.
  scene,
}

/// How a shadow map stores depths.
enum ShadowMapEncoding() {
  /// [float32] where the GPU can render into 32-bit float textures (Metal and
  /// Vulkan), [rgba8] elsewhere (OpenGL ES).
  auto,

  /// One 32-bit float per texel.
  float32,

  /// 24 bits of depth packed into the red, green and blue channels of an
  /// 8-bit RGBA texel, which every GPU can render into.
  rgba8,
}
