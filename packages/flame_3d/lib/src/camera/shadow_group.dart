part of 'world_3d.dart';

/// {@template shadow_group}
/// Worlds that share one shadow map: the objects of every world of the group
/// cast their shadows onto the objects of every other, as if they were one
/// scene.
///
/// The map is that of the lights of the world that renders first in a frame,
/// a single map or the atlas (cascades, spot and point lights): every tile
/// gets the casters of every world. With [ShadowFit.view], it is fitted to
/// what all the worlds of the group show, whichever of them renders it (see
/// [viewsVersion]).
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

  /// Combined [World3D.castersVersion] sum across all worlds in this group.
  int get castersVersion {
    var total = 0;
    for (final member in _worlds) {
      total = 0x1fffffff & (total * 31 + member._castersVersion);
    }
    return total;
  }

  /// A number that increases whenever the cameras the group's map is fitted
  /// to change.
  ///
  /// With [ShadowFit.view], the map covers what every world of the group
  /// shows, not only what the world that renders it shows: each
  /// `Scene3DComponent` of the group reports, on every frame it is drawn,
  /// whether it renders its pass or draws its retained image again, a camera
  /// that sees the part of the screen it may draw on ([noteView]), and the
  /// map is fitted to the part of the bounds of the group's worlds that these
  /// cameras see. The cameras are gathered once per frame, when the first
  /// world of the group is drawn: the camera of that world in this frame, and
  /// the cameras the others were drawn with in the previous frame (a world
  /// not drawn in the previous frame is left out). So the map, and the size
  /// it keeps from frame to frame, do not depend on which of the worlds
  /// renders it, nor on which of them reuse a retained image.
  ///
  /// The camera of a layer only changes when it moves on the screen (the 2D
  /// camera pans or zooms, the layer or an ancestor moves, the game resizes),
  /// not when its scene changes. A retained `Scene3DComponent` of the group
  /// renders again when this number changes, so that its image holds the
  /// shadows of a map fitted to what it shows.
  int get viewsVersion => _viewsVersion;
  int _viewsVersion = 0;

  // A round starts each time a world that was already drawn in the current
  // round is drawn again: once per frame when each world is drawn once per
  // frame.
  int _round = 0;

  // The cameras the map of the current round is fitted to: the world, its
  // view and its view-projection, for each world drawn in this round (the
  // one that started it) or in the previous one.
  final List<World3D> _viewWorlds = [];
  final List<Matrix4> _views = [];
  final List<Matrix4> _viewProjections = [];

  /// Reports that [world], a world of this group, is drawn in this frame,
  /// whether its host renders it or draws an image it kept, and that the
  /// camera of [view] and [projection] sees the part of the screen it may
  /// draw on.
  ///
  /// `Scene3DComponent` calls it on every frame for its world; the group
  /// reports the camera of the pass itself for a world that renders without
  /// having been reported.
  @internal
  void noteView(World3D world, Matrix4 view, Matrix4 projection) {
    _note(world, view, projection, byHost: true);
  }

  void _note(
    World3D world,
    Matrix4 view,
    Matrix4 projection, {
    required bool byHost,
  }) {
    if (!identical(world._shadowGroup, this)) {
      return;
    }
    final startsRound = _round == 0 || world._groupRound == _round;
    // A world drawn after the first of the round with another camera than
    // the one the map of the round is fitted to: the next frame fits it to
    // this one, and must be painted, also in a game that only paints changed
    // frames.
    final lags =
        !startsRound &&
        (world._groupRound < _round - 1 ||
            !_sameMatrix(world._groupView, view) ||
            !_sameMatrix(world._groupProjection, projection));
    world._groupView.setFrom(view);
    world._groupProjection.setFrom(projection);
    world._groupViewProjection
      ..setFrom(projection)
      ..multiply(view);
    world
      .._groupRound = startsRound ? ++_round : _round
      .._groupNotedByHost = byHost;
    if (startsRound) {
      _gatherViews();
    } else if (lags && _mapFollowsViews) {
      Game.notifyVisualMutation();
    }
  }

  /// Takes the cameras of the worlds drawn in this round or the previous one
  /// as those the map is fitted to, each camera once.
  void _gatherViews() {
    var count = 0;
    var changed = false;
    for (final member in _worlds) {
      if (member._groupRound < _round - 1) {
        continue;
      }
      final view = member._groupView;
      final viewProjection = member._groupViewProjection;
      if (_hasView(count, view, viewProjection)) {
        continue;
      }
      if (count == _viewWorlds.length) {
        _viewWorlds.add(member);
        _views.add(view.clone());
        _viewProjections.add(viewProjection.clone());
        changed = true;
      } else if (!identical(_viewWorlds[count], member) ||
          !_sameMatrix(_views[count], view) ||
          !_sameMatrix(_viewProjections[count], viewProjection)) {
        _viewWorlds[count] = member;
        _views[count].setFrom(view);
        _viewProjections[count].setFrom(viewProjection);
        changed = true;
      }
      count++;
    }
    if (count < _viewWorlds.length) {
      _viewWorlds.length = count;
      _views.length = count;
      _viewProjections.length = count;
      changed = true;
    }
    if (changed) {
      _viewsVersion++;
    }
  }

  /// Whether one of the first [count] cameras gathered is that of [view]
  /// and [viewProjection].
  bool _hasView(int count, Matrix4 view, Matrix4 viewProjection) {
    for (var i = 0; i < count; i++) {
      if (_sameMatrix(_viewProjections[i], viewProjection) &&
          _sameMatrix(_views[i], view)) {
        return true;
      }
    }
    return false;
  }

  /// Forgets [world], which leaves the group: its camera is left out from
  /// the next frame on.
  void _leave(World3D world) {
    _worlds.remove(world);
  }

  static bool _sameMatrix(Matrix4 a, Matrix4 b) {
    final x = a.storage;
    final y = b.storage;
    for (var i = 0; i < 16; i++) {
      if (x[i] != y[i]) {
        return false;
      }
    }
    return true;
  }

  /// The union of the bounds of the casters of the last map.
  final Aabb3 _bounds = Aabb3();

  // The frame, the cameras and the version of the last map, see
  // [_renderFor].
  GraphicsDevice? _device;
  int _frame = -1;
  int _mapViewsVersion = -1;
  int? _version;

  // Whether the last map depends on the cameras it was fitted to
  // ([ShadowFit.view]): one that does not is reused by the other worlds of
  // the frame however the cameras moved.
  bool _mapFollowsViews = true;

  /// Makes [world]'s next main pass, whose camera is set in [context],
  /// receive the group's shadow map: reused when it was rendered earlier in
  /// this frame for the same cameras (or cached via
  /// [ShadowSettings.cacheWhenStatic]) and is still bound, rendered
  /// otherwise. Returns whether the pass receives shadows.
  bool _renderFor(World3D world, RenderContext3D context, Canvas canvas) {
    // A world whose host does not report its camera (one that is not a
    // Scene3DComponent) is drawn with the camera of the pass.
    if (world._groupRound != _round ||
        (!world._groupNotedByHost &&
            (!_sameMatrix(world._groupView, context.view) ||
                !_sameMatrix(world._groupProjection, context.projection)))) {
      _note(world, context.view, context.projection, byHost: false);
    }
    final device = context.device;
    final version = _version;
    if (version != null &&
        identical(device, _device) &&
        device.frame == _frame &&
        (_mapViewsVersion == _viewsVersion || !_mapFollowsViews) &&
        context.reuseShadowMap(version)) {
      return true;
    }
    _device = device;
    _frame = device.frame;
    _mapViewsVersion = _viewsVersion;
    _version = null;

    var any = false;
    var groupCastersHash = 0;
    // With ShadowSettings.cacheStillCasters, the still casters of every
    // world, prepared with the lights of the world that renders the map.
    final lights = world._passLights;
    final keepsStill = World3D._stillCasterSettings(lights) != null;
    var groupStillHash = 0;
    for (final member in _worlds) {
      if (!identical(member._contextOrNull, context)) {
        continue;
      }
      groupCastersHash = Object.hash(
        groupCastersHash,
        member,
        member._shadowKeyVersion,
      );
      if (keepsStill) {
        member._prepareStillCasters(member, lights);
        groupStillHash = Object.hash(
          groupStillHash,
          member,
          member._stillCastersVersion,
        );
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

    final key = World3D._shadowCasterKey(this, groupCastersHash, lights);
    if (!context.beginShadowPass(
      projection: projection,
      sceneBounds: any ? _bounds : null,
      castersKey: key,
      stillCastersKey: keepsStill
          ? World3D._shadowCasterKey(this, groupStillHash, lights)
          : null,
      fitViewProjections: _viewProjections,
      fitViews: _views,
    )) {
      _mapFollowsViews = context.shadowMapFollowsViews;
      if (context.hasActiveShadows) {
        _version = context.shadowMapVersion;
        return true;
      }
      return false;
    }
    _mapFollowsViews = context.shadowMapFollowsViews;
    try {
      // Every view of the lights (each tile of the atlas) gets the casters
      // of every world.
      do {
        _recordAll(world, context, canvas);
      } while (context.advanceShadowAtlasTile());
    } finally {
      context.endShadowPass();
    }
    _version = context.shadowMapVersion;
    return true;
  }

  /// Records the casters of [world], then of the other worlds of the group
  /// rendered through [context].
  void _recordAll(World3D world, RenderContext3D context, Canvas canvas) {
    world._recordCasters(canvas);
    for (final member in _worlds) {
      if (identical(member, world) ||
          !identical(member._contextOrNull, context)) {
        continue;
      }
      member._recordCasters(canvas);
    }
  }
}
