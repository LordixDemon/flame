part of 'world_3d.dart';

/// {@template shadow_group}
/// Worlds that share one shadow map: the objects of every world of the group
/// cast their shadows onto the objects of every other, as if they were one
/// scene.
///
/// Several `Scene3DComponent` layers of a 2D game are separate scenes, each
/// rendered in a pass of its own at its own priority among the 2D components:
/// buildings below some 2D labels, characters above them, for instance. Put
/// their worlds in one group and a character's shadow falls on a building of
/// the other layer, and a building's on the character:
///
/// ```dart
/// final shadows = ShadowGroup();
/// buildings.world.shadowGroup = shadows;
/// characters.world.shadowGroup = shadows;
/// ```
///
/// The map is rendered once per frame (per frame of the [GraphicsDevice] the
/// worlds render with), by the first world of the group that renders: before
/// its main pass, it renders the objects of every world of the group that
/// renders with the same device into the map, through [projection]. The
/// worlds that render after it in the frame reuse the map without rendering
/// it again (see [RenderContext3D.reuseShadowMap]), unless another shadow map
/// was rendered in between, in which case they render the group's map again.
///
/// The light that casts the shadows and its [ShadowSettings] are those of the
/// first world, and so is the camera a [ShadowFit.view] map is fitted to:
///
/// - give every world of the group the same lights (the same directions, in
///   the same order), so that each world's shaders tell the light that casts
///   the shadows from the others;
/// - render first the world whose layer covers the most of the screen, or
///   give the settings [ShadowSettings.bounds] that cover what the others
///   show with [ShadowFit.scene]: receivers outside the map are lit.
/// {@endtemplate}
class ShadowGroup() {
  /// {@macro shadow_group}
  this;

  /// The projection the group's shadow map is rendered with.
  final DirectionalShadowProjection projection = DirectionalShadowProjection();

  final List<World3D> _worlds = [];

  /// The worlds of the group, in the order they joined it (see
  /// [World3D.shadowGroup]).
  List<World3D> get worlds => List.unmodifiable(_worlds);

  /// The union of the bounds of the casters of the last map.
  final Aabb3 _bounds = Aabb3();

  // The frame and the version of the last map, see [_renderFor].
  GraphicsDevice? _device;
  int _frame = -1;
  int? _version;

  /// Makes [world]'s next main pass, whose camera is set in [context],
  /// receive the group's shadow map: reused when it was rendered earlier in
  /// this frame and is still bound, rendered otherwise. Returns whether the
  /// pass receives shadows.
  bool _renderFor(World3D world, RenderContext3D context, Canvas canvas) {
    final device = context.device;
    final version = _version;
    if (version != null &&
        identical(device, _device) &&
        device.frame == _frame &&
        context.reuseShadowMap(version)) {
      return true;
    }
    _device = device;
    _frame = device.frame;
    _version = null;

    // Every world of the group that renders with this context casts.
    var any = false;
    for (final member in _worlds) {
      if (!identical(member._contextOrNull, context)) {
        continue;
      }
      final bounds = member.sceneBounds;
      if (bounds == null) {
        continue;
      }
      if (any) {
        _bounds.hull(bounds);
      } else {
        _bounds.copyFrom(bounds);
        any = true;
      }
    }
    if (!context.beginShadowPass(
      projection: projection,
      sceneBounds: any ? _bounds : null,
    )) {
      return false;
    }
    try {
      world._recordCasters(canvas);
      for (final member in _worlds) {
        if (identical(member, world) ||
            !identical(member._contextOrNull, context)) {
          continue;
        }
        member._recordCasters(canvas);
      }
    } finally {
      context.endShadowPass();
    }
    _version = context.shadowMapVersion;
    return true;
  }
}
