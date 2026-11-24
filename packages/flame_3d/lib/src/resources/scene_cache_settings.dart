/// Whether an `Object3D`'s draws can live in a world's cached static
/// color+depth target (`StaticSceneCacheSettings`).
enum SceneCacheMotion() {
  /// Automatically placed in the static cache when opaque, unskinned, in depth
  /// layer `0`, and drawn with a non-animated material
  /// (`!isStaticCacheDynamic`).
  auto,

  /// Always rendered live on every frame; changes to this object never
  /// invalidate the static cache.
  dynamic,
}

/// Configuration for `World3D.staticSceneCache`: caches opaque static layer-0
/// geometry into reusable color and packed clip-depth textures when the static
/// scene and camera have held still for [stillFrames] frames.
class StaticSceneCacheSettings({
  /// Whether static scene caching is active.
  bool enabled = true,

  int stillFrames = 2,

  /// When `true` and a split still/moving directional shadow map is active,
  /// projects moving-caster shadows onto cached static surfaces inside the
  /// fullscreen restore pass.
  bool projectMovingShadows = true,

  /// When `true`, cache population and cache-miss frames still render with the
  /// layer's full MSAA sample count (keeping cached static surfaces
  /// antialiased), while cache-hit restore passes render into a `1x` target to
  /// avoid per-frame MSAA resolve bandwidth.
  bool restoreWithoutMsaa = false,
}) {
  /// Whether static scene caching is active.
  bool enabled = enabled;

  /// Consecutive unchanged static-scene and camera frames required before
  /// populating the cache (`>= 1`). Higher values avoid populating during brief
  /// camera pans or animations.
  int stillFrames = stillFrames < 1 ? 1 : stillFrames;

  /// When `true` and a split still/moving directional shadow map is active,
  /// projects moving-caster shadows onto cached static surfaces inside the
  /// fullscreen restore pass.
  bool projectMovingShadows = projectMovingShadows;

  /// Whether cache-hit restore passes render into a `1x` (non-MSAA) target
  /// while static cache population and cache-miss passes keep full MSAA.
  bool restoreWithoutMsaa = restoreWithoutMsaa;
}
