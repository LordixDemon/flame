import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/render_pass.dart';
import 'package:flame/src/camera/world_spatial_index.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/core/event_bus.dart';
import 'package:flame/src/components/core/world_query.dart';
import 'package:flame/src/components/mixins/coordinate_transform.dart';
import 'package:flame/src/components/mixins/ignore_events.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/rendering/decorator.dart';
import 'package:meta/meta.dart';
import 'package:vector_math/vector_math.dart';

/// The root component for all game world elements.
///
/// The primary feature of this component is that it disables regular rendering,
/// and allows itself to be rendered through a [CameraComponent] only. The
/// updates proceed through the world tree normally.
///
/// The [priority] of the world by default is the maximum 32bit negative int
/// value to ensure it will always be earlier in the component tree than a
/// [CameraComponent].
class World({
  super.children,
  super.priority = -0x7fffffff,
  bool spatialIndexEnabled = false,
  double spatialCellSize = 256.0,
  super.key,
}) extends Component with CustomTraversal implements CoordinateTransform {
  /// Optional decorator chain applied when this world is rendered through a
  /// [CameraComponent] (also used by `WorldRoute.addRenderEffect`).
  final Decorator decorator = Decorator();

  /// Optional callback invoked before each [RenderPass] when observed by a
  /// multi-pass [CameraComponent].
  void Function(Canvas canvas, RenderPass pass)? beforePassCallback;

  /// Optional callback invoked after each [RenderPass] when observed by a
  /// multi-pass [CameraComponent] (for example to flush shared 3D or sprite
  /// pass buffers).
  void Function(Canvas canvas, RenderPass pass)? afterPassCallback;

  bool _spatialIndexEnabled = spatialIndexEnabled;
  double _spatialCellSize = spatialCellSize;
  int _lastSpatialRenderedCount = 0;

  WorldSpatialIndex? _spatialIndex;
  WorldEventBus? _eventBus;
  List<WorldQuery<Component>>? _queries;
  final List<Component> _spatialRenderScratch = <Component>[];

  /// Scoped typed event bus for components inside this world. Any events queued
  /// via [WorldEventBus.enqueue] are automatically drained at the end of
  /// [updateTree].
  WorldEventBus get eventBus => _eventBus ??= WorldEventBus();

  /// Registers and populates a reactive [WorldQuery] maintained incrementally
  /// whenever direct children of this world are added or removed.
  WorldQuery<T> registerQuery<T extends Component>(WorldQuery<T> query) {
    query.rebuild(children);
    (_queries ??= <WorldQuery<Component>>[]).add(query);
    return query;
  }

  /// Detaches a previously registered [WorldQuery].
  bool unregisterQuery(WorldQuery<Component> query) =>
      _queries?.remove(query) ?? false;

  /// Broadphase 2D spatial index (`SpatialGrid2D` + `Transform2D.version`
  /// tracking) for direct [PositionComponent] children of this world.
  WorldSpatialIndex get spatialIndex =>
      _spatialIndex ??= WorldSpatialIndex(cellSize: _spatialCellSize);

  /// Whether [renderFromCamera] and [componentsAtLocation] use [spatialIndex]
  /// for `O(visible)` frustum rendering and `O(1)` point hit-testing.
  bool get spatialIndexEnabled => _spatialIndexEnabled;
  set spatialIndexEnabled(bool value) {
    if (_spatialIndexEnabled == value) {
      return;
    }
    _spatialIndexEnabled = value;
    if (value) {
      spatialIndex.markMembershipDirty();
    } else {
      _spatialIndex?.clear();
    }
  }

  /// Cell size in world units used by [spatialIndex].
  double get spatialCellSize => _spatialCellSize;
  set spatialCellSize(double value) {
    assert(value > 0, 'spatialCellSize must be positive: $value');
    _spatialCellSize = value;
    _spatialIndex?.rebuildWithCellSize(value);
  }

  /// Number of spatially indexed [PositionComponent] children rendered during
  /// the most recent [renderFromCamera] pass.
  @visibleForTesting
  int get lastSpatialRenderedCount => _lastSpatialRenderedCount;

  @override
  void onMount() {
    super.onMount();
    if (_spatialIndexEnabled) {
      spatialIndex.markMembershipDirty();
    }
  }

  @override
  void updateSubtree(double dt) {
    super.updateSubtree(dt);
    final bus = _eventBus;
    if (bus != null && bus.pendingCount > 0) {
      bus.flushQueue();
    }
  }

  @override
  void onChildrenChanged(Component child, ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    _spatialIndex?.markMembershipDirty();
    final queries = _queries;
    if (queries != null) {
      for (var i = 0; i < queries.length; i++) {
        queries[i].handleChildChanged(child, type);
      }
    }
  }

  /// Appends all spatially indexed direct [PositionComponent] children
  /// overlapping [worldRect] into [out] ordered by `(priority, sortKey)`.
  int querySpatialRect(Rect worldRect, List<PositionComponent> out) {
    final idx = spatialIndex..syncWithChildren(children);
    return idx.queryRectOrdered(worldRect, out);
  }

  /// Appends all spatially indexed direct [PositionComponent] children
  /// intersecting `(center, radius)` into [out].
  int querySpatialRadius(
    Vector2 center,
    double radius,
    List<PositionComponent> out,
  ) {
    final idx = spatialIndex..syncWithChildren(children);
    return idx.queryRadius(center.x, center.y, radius, out);
  }

  /// Appends all spatially indexed direct [PositionComponent] children
  /// containing [point] into [out].
  int querySpatialPoint(Vector2 point, List<PositionComponent> out) {
    final idx = spatialIndex..syncWithChildren(children);
    return idx.queryPoint(point.x, point.y, out);
  }

  @override
  void renderTree(Canvas canvas) {}

  /// Hook invoked immediately before [renderFromCamera] for [pass] when
  /// [CameraComponent.renderPasses] is non-empty.
  void onBeforeRenderPass(Canvas canvas, RenderPass pass) {}

  /// Hook invoked immediately after [renderFromCamera] for [pass] when
  /// [CameraComponent.renderPasses] is non-empty.
  void onAfterRenderPass(Canvas canvas, RenderPass pass) {}

  void _renderSpatialCameraPass(Canvas canvas) {
    if (!isActiveForCurrentGraphicsTier) {
      return;
    }
    final camera = CameraComponent.currentCamera;
    if (camera == null || camera.parent == null) {
      super.renderTree(canvas);
      return;
    }

    final activePass = CameraComponent.currentRenderPass;
    if (activePass == null ||
        !activePass.exclusiveToMultiPass ||
        this is MultiPassComponent) {
      render(canvas);
    }

    final idx = spatialIndex..syncWithChildren(children);
    final (visibleIndexed, visibleCullables) = idx.collectVisibleForRender(
      camera.visibleWorldRect,
      _spatialRenderScratch,
    );
    _lastSpatialRenderedCount = visibleIndexed;
    camera.recordCullDecisionsBulk(
      visible: visibleCullables,
      culled: idx.indexedCullableCount - visibleCullables,
    );

    for (var i = 0; i < _spatialRenderScratch.length; i++) {
      renderChild(canvas, _spatialRenderScratch[i]);
    }

    afterChildrenRendered(canvas);
    if (debugMode) {
      renderDebugMode(canvas);
    }
  }

  /// The rendering method invoked by the [CameraComponent].
  ///
  /// If you want to do changes to the rendering of the world, this is the
  /// method that you want to override, not [renderTree].
  void renderFromCamera(Canvas canvas) {
    assert(CameraComponent.currentCamera != null);
    final renderFn = _spatialIndexEnabled
        ? _renderSpatialCameraPass
        : super.renderTree;
    if (decorator.isLastDecorator) {
      renderFn(canvas);
    } else {
      decorator.applyChain(renderFn, canvas);
    }
  }

  @override
  Iterable<Component> componentsAtLocation<T>(
    T locationContext,
    List<T>? nestedContexts,
    T? Function(CoordinateTransform, T) transformContext,
    bool Function(Component, T) checkContains,
  ) sync* {
    if (!isActiveForCurrentGraphicsTier) {
      return;
    }
    if (!_spatialIndexEnabled || locationContext is! Vector2) {
      yield* super.componentsAtLocation(
        locationContext,
        nestedContexts,
        transformContext,
        checkContains,
      );
      return;
    }

    if (this is IgnoreEvents && (this as IgnoreEvents).ignoreEvents) {
      return;
    }

    final idx = spatialIndex..syncWithChildren(children);
    final candidates = <Component>[];
    idx.collectCandidatesAtPoint(
      locationContext.x,
      locationContext.y,
      candidates,
    );

    for (var i = 0; i < candidates.length; i++) {
      yield* candidates[i].componentsAtLocation(
        locationContext,
        nestedContexts,
        transformContext,
        checkContains,
      );
    }
    if (checkContains(this, locationContext)) {
      yield this;
    }
  }

  @override
  bool containsLocalPoint(Vector2 point) => true;

  @override
  Vector2? localToParent(Vector2 point) => null;

  @override
  Vector2? parentToLocal(Vector2 point) => null;
}
