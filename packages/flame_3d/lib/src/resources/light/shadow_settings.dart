import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';

/// {@template shadow_settings}
/// How a [DirectionalLight], [SpotLight], or [PointLight] casts shadows: the
/// resolution of its shadow map (or tile in the unified `ShadowAtlas3D`), the
/// part of the scene the map covers, how shadows look, and the biases that keep
/// surfaces from shadowing themselves.
///
/// A [DirectionalLight] can split its map into up to `4` cascades
/// ([cascades]), sharper near the camera, that blend into each other. Up to
/// `2` [SpotLight]s cast perspective shadows, and one [PointLight] casts
/// shadows all around it (two paraboloid hemispheres). A lone light with one
/// map renders it on its own; cascades, a point light and several
/// shadow-casting lights share the tiles of one atlas. Every built-in
/// receiver, and every shader that includes `flame_3d/shadows.glsl`, reads
/// both.
/// {@endtemplate}
class ShadowSettings({
  /// The width and height of the shadow map (or base tile), in texels: more is
  /// sharper and costs more memory and fill rate.
  int resolution = 1024,

  /// The part of the scene the shadow map covers.
  var ShadowFit fit = ShadowFit.view,

  /// The region that receives shadows, in world space, instead of the bounds
  /// of the whole scene: see [ShadowFit]. Casters outside it still cast
  /// shadows into it. [ShadowFit.fixed] needs it.
  var Aabb3? bounds,

  /// With [ShadowFit.fixed], the region that holds every caster, in world
  /// space: the depth range of the map reaches from the far end of [bounds]
  /// back towards the light over all of it, instead of over the bounds of
  /// the scene. `null` takes [bounds]. A caster nearer to the light than
  /// every corner of it is cut off where it is nearer, so let it hold
  /// everything that can cast, at the highest it can rise. Other fits ignore
  /// it.
  var Aabb3? casterBounds,

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
  /// When the lights share the atlas (cascades, a point light, several
  /// lights), it is skipped only if every light that casts shadows sets it.
  var bool cacheWhenStatic = false,

  /// Whether the depths of the casters that stand still are kept from frame
  /// to frame in a layer of their own, so that a frame only draws the
  /// casters that changed, over a copy of that layer: the cost of the shadow
  /// pass follows what moves, and the map holds the same depths as one
  /// rendered whole.
  ///
  /// The engine tells still casters from moving ones by its own change
  /// tracking (see `Object3D.shadowMotion`): a caster that changed in the
  /// last [stillCasterFrames] renders of the shadows is drawn in every
  /// frame, the others come from the kept layer, which is rendered again
  /// when one of them changes, appears or disappears, when a light that
  /// casts shadows changes, or when the casters that stopped moving join it.
  /// The map is also reused whole while nothing changed, as with
  /// [cacheWhenStatic]. When the lights share the atlas (cascades, a point
  /// light, several lights), it applies only if every light that casts
  /// shadows sets it. It costs a second texture of the size of the map (or
  /// atlas), kept with the layer, and one copy of the layer per frame that
  /// draws moving casters; the receivers do not change.
  var bool cacheStillCasters = false,

  /// With [cacheStillCasters], the number of renders of the shadows a caster
  /// must stay unchanged before it joins the kept layer of still casters,
  /// from `1`; `30` by default, half a second at 60 frames per second.
  ///
  /// A caster that moves again after it joined the layer has the layer
  /// rendered again; a larger value keeps casters that pause briefly (a
  /// token between two hops) out of it.
  int stillCasterFrames = 30,

  /// Number of directional shadow cascades (`1`..`4`). The last cascade
  /// covers what a single map would; each other cascade covers a part of it
  /// (see [cascadeSplits]) with a map of the same resolution, so it is
  /// sharper.
  int cascades = 1,

  /// The fraction `(0..1)` of the distance covered by cascade `0`, from
  /// which the splits of the others derive when [cascadeSplits] is `null`.
  var double cascadeSplitRatio = 0.28,

  /// Explicit increasing fractions in `(0..1]`, one per cascade (e.g.
  /// `[0.12, 0.32, 0.62, 1.0]` for 4 cascades): with a perspective camera
  /// and [ShadowFit.view], cascade `c` covers what the camera sees up to that
  /// fraction of [maxDistance] (or, without one, of the farthest point of the
  /// receiving region); otherwise that fraction of the receiving region,
  /// around its center. The last cascade always covers it all, so its split
  /// may be left out: the list holds [cascades] values, or one fewer.
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
    this.stillCasterFrames = stillCasterFrames;
    final splits = cascadeSplits;
    if (splits != null) {
      if (splits.length != cascades && splits.length != cascades - 1) {
        throw ArgumentError.value(
          splits,
          'cascadeSplits',
          'Must have one split per cascade ($cascades), or one per cascade '
              'but the last',
        );
      }
      for (var i = 0; i < splits.length; i++) {
        final split = splits[i];
        if (!(split > 0 && split <= 1) || (i > 0 && split <= splits[i - 1])) {
          throw ArgumentError.value(
            splits,
            'cascadeSplits',
            'Must increase within (0, 1]',
          );
        }
      }
    }
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

  /// With [cacheStillCasters], the number of renders of the shadows a caster
  /// must stay unchanged before it joins the kept layer of still casters,
  /// from `1`.
  int get stillCasterFrames => _stillCasterFrames;
  set stillCasterFrames(int value) {
    if (value < 1) {
      throw ArgumentError.value(
        value,
        'stillCasterFrames',
        'Must be 1 or more',
      );
    }
    _stillCasterFrames = value;
  }

  int _stillCasterFrames = 30;

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

  /// The whole of [ShadowSettings.bounds], with a depth range over
  /// [ShadowSettings.casterBounds], held: the projection depends on the
  /// light's direction, these two boxes and the resolution alone, not on the
  /// camera, the bounds of the scene, nor earlier frames. As long as the
  /// light does not turn, every frame has the same projection to the last
  /// bit, so the edges of the shadows stay where they are, and the kept map
  /// of [ShadowSettings.cacheWhenStatic] and the kept layer of
  /// [ShadowSettings.cacheStillCasters] last while the casters do not change.
  /// The map covers the bounds exactly: [ShadowSettings.stabilize] does not
  /// apply. Needs [ShadowSettings.bounds]: a shadow pass without them throws
  /// a [StateError].
  fixed,
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

/// How the shadow of an `Object3D` is kept by
/// [ShadowSettings.cacheStillCasters], see `Object3D.shadowMotion`.
enum ShadowCasterMotion() {
  /// The engine decides from its own change tracking: a caster that changed
  /// in a way it sees (moved, shown, a new pose, new instances, ...) in the
  /// last [ShadowSettings.stillCasterFrames] renders of the shadows is drawn
  /// in every frame, the others are kept with the still casters.
  auto,

  /// Kept with the still casters whatever it does: each change the engine
  /// sees renders the layer of still casters again. For a caster that
  /// changes rarely and costs much to draw, such as a large terrain.
  still,

  /// Drawn in every frame, never kept: for a caster that changes in ways
  /// the engine cannot see, such as vertices written in place by your own
  /// code. While such a caster is in a world, its shadow map is never
  /// reused whole.
  moving,
}

/// The casters a shadow pass records, see
/// `RenderContext3D.shadowCasterLayer`.
enum ShadowCasterLayer() {
  /// Every caster: the pass renders the map whole.
  all,

  /// Only the still casters: the pass renders the layer that
  /// [ShadowSettings.cacheStillCasters] keeps.
  still,

  /// Only the moving casters: the pass draws them over a copy of the kept
  /// layer of still casters.
  moving,
}
