import 'dart:math';
import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/scene_layer_component.dart';
import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/game/flame_game.dart';
import 'package:meta/meta.dart';

/// Update-tick behavior for off-screen [CullWhenOffscreen] components.
enum OffscreenTickMode() {
  /// Updates every frame regardless of camera visibility (default).
  fullRate,

  /// Decimates `updateTree` to once every [OffscreenTickPolicy.frameInterval]
  /// frames while off-screen, passing the exact accumulated `dt`.
  everyNFrames,

  /// Suspends `updateTree` completely while off-screen (`0` CPU cost).
  sleepWhenOffscreen,
}

/// Configures update-LOD / tick decimation on [CullWhenOffscreen] components.
@immutable
class const OffscreenTickPolicy._({
  required this.mode,
  this.frameInterval = 1,
}) {
  this : assert(frameInterval >= 1, 'frameInterval must be >= 1');

  /// Updates at full framerate even when off-screen.
  static const OffscreenTickPolicy fullRate = OffscreenTickPolicy._(
    mode: OffscreenTickMode.fullRate,
  );

  /// Suspends `updateTree` completely while off-screen.
  static const OffscreenTickPolicy sleepWhenOffscreen = OffscreenTickPolicy._(
    mode: OffscreenTickMode.sleepWhenOffscreen,
  );

  /// Updates once every [interval] frames (`>= 2`) while off-screen with
  /// accurate accumulated `dt`.
  const OffscreenTickPolicy.everyNFrames(int interval)
    : this._(
        mode: interval <= 1
            ? OffscreenTickMode.fullRate
            : OffscreenTickMode.everyNFrames,
        frameInterval: interval,
      );

  /// Active tick mode while off-screen.
  final OffscreenTickMode mode;

  /// Frame decimation stride used when [mode] is
  /// [OffscreenTickMode.everyNFrames].
  final int frameInterval;

  @override
  bool operator ==(Object other) {
    return other is OffscreenTickPolicy &&
        other.mode == mode &&
        other.frameInterval == frameInterval;
  }

  @override
  int get hashCode => Object.hash(mode, frameInterval);
}

/// Skips drawing a [PositionComponent] while it is off-screen.
///
/// Supports both uniform [cullPadding] and directional [cullBoundsOutset]
/// (useful for tall 2.5D/3D towers extending in `-Y` or long directional
/// shadows without wasting padding on opposite sides), and caches axis-aligned
/// world bounds across stationary frames via `Transform2D.version`.
///
/// "On-screen" is decided against `CameraComponent.cullWorldRect`, which
/// covers the active trauma shake of the camera, and the bounds are shifted
/// by the parallax of any `SceneLayerComponent` the component is drawn
/// through. Nothing is culled while the component is recorded into a
/// camera-independent cache (a `Snapshot` or a cached `SceneLayerComponent`).
mixin CullWhenOffscreen on PositionComponent {
  /// Turns culling on or off for this component only.
  bool cullingEnabled = true;

  /// Turns on an extra check that helps to find culling mistakes in debug mode.
  static bool debugVerifyCulledSubtrees = false;

  /// Extra uniform space, in world units, added around [cullBounds] before
  /// checking if the component is on-screen.
  double cullPadding = 0;

  /// Asymmetric world-unit expansion `(left, top, right, bottom)` applied to
  /// [cullBounds] in addition to [cullPadding].
  ///
  /// Positive magnitudes expand outward on each respective side (for example,
  /// `const Rect.fromLTRB(12, 120, 48, 8)` expands 120 world units upward for a
  /// tall 3D spire and 48 units right for an evening cast shadow).
  Rect cullBoundsOutset = Rect.zero;

  Rect? _cachedWorldBounds;
  int _cachedTransformVersion = -1;
  double _cachedSizeX = double.nan;
  double _cachedSizeY = double.nan;
  double _cachedAnchorX = double.nan;
  double _cachedAnchorY = double.nan;
  bool _wasCulledLastFrame = false;
  int _cullBoundsComputeCount = 0;

  OffscreenTickPolicy _offscreenTickPolicy = OffscreenTickPolicy.fullRate;
  double _offscreenAccumulatedDt = 0.0;
  int _offscreenFrameCounter = 0;
  int _skippedOffscreenTicks = 0;

  /// Controls whether off-screen components decimate or sleep their
  /// `updateTree(dt)` simulation ticks.
  OffscreenTickPolicy get offscreenTickPolicy => _offscreenTickPolicy;
  set offscreenTickPolicy(OffscreenTickPolicy value) {
    if (_offscreenTickPolicy == value) {
      return;
    }
    _offscreenTickPolicy = value;
    _offscreenAccumulatedDt = 0.0;
    _offscreenFrameCounter = 0;
    final needsGate = value.mode != OffscreenTickMode.fullRate;
    if (hasOffscreenTickGate != needsGate) {
      hasOffscreenTickGate = needsGate;
      if (isMounted) {
        Component.invalidateFlatTraversalLists();
      }
    }
  }

  /// Number of `updateTree` ticks skipped by [offscreenTickPolicy].
  int get skippedOffscreenTicks => _skippedOffscreenTicks;

  bool _isOffscreenForUpdateTick() {
    if (!cullingEnabled) {
      return false;
    }
    final world = _world;
    if (world == null) {
      return false;
    }
    final game = findGame();
    if (game is FlameGame && identical(game.camera.world, world)) {
      if (game.camera.parent != null) {
        return !_overlapsCullRect(game.camera, _expandedBounds(cullBounds));
      }
    }
    return _wasCulledLastFrame;
  }

  @override
  @internal
  void runGatedUpdateSubtree(double dt) {
    if (dt <= 0.0) {
      runDefaultOrCustomSubtree(dt);
      return;
    }
    final policy = _offscreenTickPolicy;
    if (policy.mode == OffscreenTickMode.fullRate ||
        !_isOffscreenForUpdateTick()) {
      final fireDt = dt + _offscreenAccumulatedDt;
      _offscreenAccumulatedDt = 0.0;
      _offscreenFrameCounter = 0;
      runDefaultOrCustomSubtree(fireDt);
      return;
    }

    if (policy.mode == OffscreenTickMode.sleepWhenOffscreen) {
      _offscreenAccumulatedDt = 0.0;
      _skippedOffscreenTicks++;
      return;
    }

    // OffscreenTickMode.everyNFrames
    _offscreenAccumulatedDt += dt;
    _offscreenFrameCounter++;
    if (_offscreenFrameCounter < policy.frameInterval) {
      _skippedOffscreenTicks++;
      return;
    }
    _offscreenFrameCounter = 0;
    final fireDt = _offscreenAccumulatedDt;
    _offscreenAccumulatedDt = 0.0;
    runDefaultOrCustomSubtree(fireDt);
  }

  /// Whether this component was skipped by frustum culling on its most recent
  /// camera render check.
  bool get wasCulledLastFrame {
    final w = _world;
    if (w != null && w.spatialIndexEnabled && cullingEnabled) {
      final idx = w.spatialIndex;
      if (idx.renderPassStamp > 0 && idx.containsIndexed(this)) {
        return _lastSpatialRenderStamp != idx.renderPassStamp;
      }
    }
    return _wasCulledLastFrame;
  }

  bool _skipNextCullCheck = false;
  int _lastSpatialRenderStamp = -1;

  /// Marks this component accepted by `WorldSpatialIndex` on [stamp] so
  /// [_isOffscreen] skips redundant overlap evaluation and double telemetry.
  @internal
  void markSpatialVisible(int stamp) {
    _wasCulledLastFrame = false;
    _lastSpatialRenderStamp = stamp;
    _skipNextCullCheck = true;
  }

  /// Number of times the fast-path world bounds rectangle was recomputed (used
  /// in tests to verify `Transform2D.version` caching on stationary frames).
  @visibleForTesting
  int get cullBoundsComputeCount => _cullBoundsComputeCount;

  /// The area of the world that this component takes up.
  ///
  /// By default this is the box made by the position, size, anchor, scale and
  /// angle of the component and its parents, cached across frames whenever
  /// `transform.version`, `size`, and `anchor` are unchanged for unrotated
  /// components in direct [World] coordinates (either direct children of a
  /// [World] or nested under plain non-transforming [Component] layers).
  Rect get cullBounds {
    if (angle == 0 && (_hasDirectWorldCoords || parent is World)) {
      final txVersion = transform.version;
      final sx = size.x;
      final sy = size.y;
      final ax = anchor.x;
      final ay = anchor.y;
      final cached = _cachedWorldBounds;
      if (cached != null &&
          _cachedTransformVersion == txVersion &&
          _cachedSizeX == sx &&
          _cachedSizeY == sy &&
          _cachedAnchorX == ax &&
          _cachedAnchorY == ay) {
        return cached;
      }
      _cullBoundsComputeCount++;
      final width = sx * scale.x;
      final height = sy * scale.y;
      final left = position.x - ax * width;
      final top = position.y - ay * height;
      final computed = Rect.fromLTRB(
        min(left, left + width),
        min(top, top + height),
        max(left, left + width),
        max(top, top + height),
      );
      _cachedWorldBounds = computed;
      _cachedTransformVersion = txVersion;
      _cachedSizeX = sx;
      _cachedSizeY = sy;
      _cachedAnchorX = ax;
      _cachedAnchorY = ay;
      return computed;
    }
    _cachedWorldBounds = null;
    _cullBoundsComputeCount++;
    return toAbsoluteRect();
  }

  World? _world;
  bool _hasDirectWorldCoords = false;
  List<SceneLayerComponent>? _sceneLayers;

  /// Whether this component has zero transforming ancestors between itself and
  /// its owning [World].
  @internal
  bool get hasDirectWorldCoords => _hasDirectWorldCoords;

  @mustCallSuper
  @override
  void onMount() {
    super.onMount();
    _world = enclosingWorld();
    _hasDirectWorldCoords = hasDirectWorldCoordinates();
    _sceneLayers = SceneLayerComponent.ancestorLayersOf(this);
    _cachedWorldBounds = null;
  }

  @mustCallSuper
  @override
  void onRemove() {
    _world = null;
    _hasDirectWorldCoords = false;
    _sceneLayers = null;
    _cachedWorldBounds = null;
    super.onRemove();
  }

  /// Whether [bounds] (in the coordinates this component is laid out in)
  /// reaches into what [camera] can show this frame.
  ///
  /// A parallax `SceneLayerComponent` between this component and the world
  /// draws its subtree shifted on the canvas, so [bounds] are shifted by the
  /// same amount before they are compared.
  bool _overlapsCullRect(CameraComponent camera, Rect bounds) {
    final visible = camera.cullWorldRect;
    final layers = _sceneLayers;
    if (layers == null) {
      return visible.overlaps(bounds);
    }
    var shiftX = 0.0;
    var shiftY = 0.0;
    for (var i = 0; i < layers.length; i++) {
      shiftX += layers[i].parallaxShiftX(camera);
      shiftY += layers[i].parallaxShiftY(camera);
    }
    return bounds.left + shiftX < visible.right &&
        visible.left < bounds.right + shiftX &&
        bounds.top + shiftY < visible.bottom &&
        visible.top < bounds.bottom + shiftY;
  }

  @override
  void renderTree(Canvas canvas) {
    if (_isOffscreen()) {
      return;
    }
    super.renderTree(canvas);
  }

  Rect _expandedBounds(Rect bounds) {
    final p = cullPadding;
    final outset = cullBoundsOutset;
    if (p == 0.0 && outset == Rect.zero) {
      return bounds;
    }
    return Rect.fromLTRB(
      bounds.left - p - outset.left,
      bounds.top - p - outset.top,
      bounds.right + p + outset.right,
      bounds.bottom + p + outset.bottom,
    );
  }

  bool _isOffscreen() {
    if (_skipNextCullCheck) {
      _skipNextCullCheck = false;
      _wasCulledLastFrame = false;
      return false;
    }
    final world = _world;
    // The innermost camera is the one currently rendering this component.
    // There is none while the subtree is recorded into a camera-independent
    // cache, and then nothing may be left out.
    final camera = CameraComponent.currentCamera;
    if (!cullingEnabled || world == null || camera == null) {
      _wasCulledLastFrame = false;
      return false;
    }
    if (camera.world != world) {
      _wasCulledLastFrame = false;
      return false;
    }
    final bounds = cullBounds;
    final expanded = _expandedBounds(bounds);
    final offscreen = !_overlapsCullRect(camera, expanded);
    assert(_debugVerifyCulledSubtree(offscreen, camera, expanded));
    _wasCulledLastFrame = offscreen;
    camera.recordCullDecision(culled: offscreen);
    return offscreen;
  }

  /// Only used in an assert, see [debugVerifyCulledSubtrees]. Always returns
  /// true, or throws when a culled component has a visible descendant.
  bool _debugVerifyCulledSubtree(
    bool offscreen,
    CameraComponent camera,
    Rect bounds,
  ) {
    if (offscreen && debugVerifyCulledSubtrees && hasChildren) {
      // Children are measured in un-shifted coordinates, so the rectangle
      // they are compared with is moved back by the parallax of the layers.
      var visibleRect = camera.cullWorldRect;
      final layers = _sceneLayers;
      if (layers != null) {
        var shiftX = 0.0;
        var shiftY = 0.0;
        for (final layer in layers) {
          shiftX += layer.parallaxShiftX(camera);
          shiftY += layer.parallaxShiftY(camera);
        }
        visibleRect = visibleRect.shift(Offset(-shiftX, -shiftY));
      }
      final problem = _debugCulledSubtreeProblem(visibleRect, bounds);
      if (problem != null) {
        throw AssertionError(problem);
      }
    }
    return true;
  }

  /// Returns a description of the problem when this component is culled while
  /// one of its descendants is visible, and null when culling is correct.
  String? _debugCulledSubtreeProblem(Rect visibleRect, Rect bounds) {
    PositionComponent? visibleDescendant;
    var requiredPadding = 0.0;
    final pending = <Component>[this];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!current.hasChildren) {
        continue;
      }
      for (final child in current.children) {
        if (child is HasVisibility && !child.isVisible) {
          continue;
        }
        pending.add(child);
        if (child is! PositionComponent) {
          continue;
        }
        final rect = child.toAbsoluteRect();
        requiredPadding = max(
          requiredPadding,
          max(
            max(bounds.left - rect.left, rect.right - bounds.right),
            max(bounds.top - rect.top, rect.bottom - bounds.bottom),
          ),
        );
        if (visibleDescendant == null && visibleRect.overlaps(rect)) {
          visibleDescendant = child;
        }
      }
    }
    if (visibleDescendant == null) {
      return null;
    }
    return '$runtimeType is off-screen and was skipped, but its child '
        '${visibleDescendant.runtimeType} is on-screen. A skipped component '
        'also skips its children. Set cullPadding to at least '
        '${requiredPadding.ceil()} (it is now $cullPadding), or override '
        'cullBounds.';
  }
}
