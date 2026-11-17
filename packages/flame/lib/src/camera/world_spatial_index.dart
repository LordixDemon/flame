import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/camera/behaviors/camera_billboard.dart';
import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/scene_layer_component.dart';
import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/cull_when_offscreen.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/components/spatial_cull_group.dart';
import 'package:flame/src/game/transform2d.dart';
import 'package:flame/src/geometry/spatial_grid_2d.dart';
import 'package:meta/meta.dart';

class _IndexedNode({
  required final PositionComponent component,
  required final bool isDirectWorldChild,
}) {
  int lastTxVersion = -1;
  double lastSizeX = double.nan;
  double lastSizeY = double.nan;
  double lastAnchorX = double.nan;
  double lastAnchorY = double.nan;
  double lastPadding = double.nan;
  Rect lastOutset = Rect.zero;
  int visibleStamp = -1;
}

/// What one camera pass sees. A pass that is started while another pass over
/// the same index is still rendering (a camera or render texture inside the
/// world that looks at this world again) gets a state of its own, so the pass
/// around it finds its buckets and visibility marks untouched afterwards.
class _RenderPassState() {
  int stamp = 0;

  final Map<Component, List<Component>> visibleByContainer =
      HashMap<Component, List<Component>>.identity();

  /// Nodes visible in this pass. Only nested passes use it; the outermost
  /// pass marks nodes with its stamp, which costs nothing per frame.
  final Set<_IndexedNode> visibleNodes = HashSet<_IndexedNode>.identity();
}

/// Native `SpatialGrid2D`-backed spatial index for `World`, accelerating camera
/// frustum culling from `O(N)` to `O(visible)` and 2D point hit-testing from
/// `O(N)` to `O(1)` across both direct `World` children and nested layer
/// hierarchies while preserving exact `(priority, sortKey, mountOrder)` draw
/// and input ordering.
///
/// ## What is indexed
///
/// A `PositionComponent` without children and with a positive `size` is an
/// indexed leaf, measured by its `size` box; a `CullWhenOffscreen` component
/// is a leaf measured by `cullBounds` plus padding. Containers whose children
/// are all leaves (or such containers) render only their visible children.
///
/// ## Hit-testing
///
/// A leaf is only offered to hit-testing when the point lies inside those
/// bounds, so a leaf whose `containsLocalPoint` reaches outside of its `size`
/// box should mix in `CullWhenOffscreen` with a matching padding.
/// Containers are different: a container that can be hit itself is always
/// offered. Only containers that are known to have no hit area of their own
/// (plain `Component`, `SceneLayerComponent` and `SpatialCullGroup`
/// instances, not subclasses) are skipped when none of their leaves is under
/// the point.
///
/// ## Nested passes
///
/// A world may be rendered again while it is being rendered (an in-world
/// camera, mirror or `RenderTextureComponent` that looks at the same world).
/// Each pass keeps its own visibility state, see [beginRenderPass].
class WorldSpatialIndex({
  double cellSize = 256.0,
  final int initialCapacity = 128,
}) {
  /// Currently executing spatial camera render pass (`null` outside
  /// `World._renderSpatialCameraPass`), allowing pure-indexed nested layer
  /// containers to render only their `O(visible)` children.
  @internal
  static WorldSpatialIndex? activeRenderIndex;

  double _cellSize = cellSize;

  late SpatialGrid2D<PositionComponent> _grid =
      SpatialGrid2D<PositionComponent>(
        cellSize: _cellSize,
        initialCapacity: initialCapacity,
      );

  final Map<PositionComponent, _IndexedNode> _indexedNodes =
      HashMap<PositionComponent, _IndexedNode>.identity();
  final List<_IndexedNode> _nodeList = <_IndexedNode>[];
  final List<Component> _unindexed = <Component>[];
  final Set<Component> _pureIndexedContainers = HashSet<Component>.identity();

  /// Pure containers that hit-testing may skip when none of their leaves is
  /// under the point: neither they nor any container below them can be hit.
  final Set<Component> _hitSkippableContainers = HashSet<Component>.identity();

  /// One state per nesting level of render passes; index `0` is the outermost
  /// pass (and the state used by a stand-alone [collectVisibleForRender]).
  final List<_RenderPassState> _passStates = <_RenderPassState>[
    _RenderPassState(),
  ];
  int _openPassCount = 0;
  final List<List<Component>> _bucketPool = <List<Component>>[];
  final List<PositionComponent> _gridScratch = <PositionComponent>[];

  int _lastGlobalTxMutation = -1;
  bool _dirtyMembership = true;
  int _syncPassCount = 0;
  int _indexedCullableCount = 0;
  int _renderPassStamp = 0;

  /// Active spatial grid cell size in world units.
  double get cellSize => _cellSize;

  /// Number of spatial-grid indexed `PositionComponent`s (both direct and
  /// nested inside world layer containers).
  int get indexedCount => _nodeList.length;

  /// Number of top-level non-leaf or non-spatial components visited during
  /// camera passes.
  int get unindexedCount => _unindexed.length;

  /// Number of indexed components mixing in [CullWhenOffscreen].
  int get indexedCullableCount => _indexedCullableCount;

  /// Number of AABB synchronization sweeps executed (for testing stationary
  /// `O(1)` skip behavior).
  int get syncPassCount => _syncPassCount;

  /// Monotonically increasing stamp for the latest [collectVisibleForRender].
  int get renderPassStamp => _renderPassStamp;

  /// Number of render passes over this index that are currently open (more
  /// than `1` while the world is rendered from within its own render pass).
  int get openRenderPassCount => _openPassCount;

  _RenderPassState get _activePass =>
      _passStates[_openPassCount > 0 ? _openPassCount - 1 : 0];

  /// Opens a camera render pass over this index and returns its nesting depth
  /// (`0` for the outermost pass).
  ///
  /// Everything that [collectVisibleForRender] computes from here on, and
  /// that `Component.renderTree` reads back through the active index, belongs
  /// to this pass until the matching [endRenderPass]. Passes nest: a pass
  /// opened while another one is rendering does not disturb it.
  @internal
  int beginRenderPass() {
    final depth = _openPassCount++;
    if (_passStates.length <= depth) {
      _passStates.add(_RenderPassState());
    }
    return depth;
  }

  /// Closes the pass opened by the matching [beginRenderPass].
  @internal
  void endRenderPass() {
    assert(_openPassCount > 0, 'endRenderPass without beginRenderPass');
    if (_openPassCount > 1) {
      // A nested pass leaves nothing behind for the pass around it.
      final state = _passStates[_openPassCount - 1];
      _releaseVisibleBuckets(state);
      state.visibleNodes.clear();
    }
    _openPassCount--;
  }

  /// Underlying [SpatialGrid2D] cell count.
  int get nonEmptyCellCount => _grid.nonEmptyCellCount;

  /// Returns `true` when [component] is currently tracked in the spatial grid.
  bool containsIndexed(PositionComponent component) =>
      _indexedNodes.containsKey(component);

  /// Rebuilds the underlying [SpatialGrid2D] with [nextCellSize] on the next
  /// synchronization sweep.
  void rebuildWithCellSize(double nextCellSize) {
    assert(nextCellSize > 0, 'nextCellSize must be positive: $nextCellSize');
    if ((_cellSize - nextCellSize).abs() <= 1e-6) {
      return;
    }
    _cellSize = nextCellSize;
    _grid = SpatialGrid2D<PositionComponent>(
      cellSize: _cellSize,
      initialCapacity: initialCapacity,
    );
    clear();
  }

  static bool _isEligibleLeafForSpatialGrid(Component child) {
    if (child is! PositionComponent) {
      return false;
    }
    if (child is CameraBillboard || child is ViewportClampedPin) {
      return false;
    }
    if (child is CullWhenOffscreen) {
      return child.cullingEnabled;
    }
    return !child.hasChildren && child.size.x > 0 && child.size.y > 0;
  }

  /// Whether [container] is certain to have no hit area of its own. Only the
  /// exact engine container types qualify: they keep the default
  /// `containsLocalPoint`, which a subclass might override.
  static bool _isHitInertContainer(Component container) {
    final type = container.runtimeType;
    return type == Component ||
        type == SceneLayerComponent ||
        type == SpatialCullGroup;
  }

  static bool _canDescendIntoContainer(Component container) {
    if (!container.hasChildren) {
      return false;
    }
    if (container is World ||
        container is CameraComponent ||
        container is CameraBillboard ||
        container is ViewportClampedPin) {
      return false;
    }
    if (container is SceneLayerComponent &&
        ((container.parallaxFactor.x - 1.0).abs() > 1e-6 ||
            (container.parallaxFactor.y - 1.0).abs() > 1e-6)) {
      return false;
    }
    return true;
  }

  static Rect _computeWorldAabb(
    PositionComponent c, {
    required bool isDirectWorldChild,
  }) {
    if (c is CullWhenOffscreen) {
      final base = c.cullBounds;
      final p = c.cullPadding;
      final out = c.cullBoundsOutset;
      if (p == 0.0 && out == Rect.zero) {
        return base;
      }
      return Rect.fromLTRB(
        base.left - p - out.left,
        base.top - p - out.top,
        base.right + p + out.right,
        base.bottom + p + out.bottom,
      );
    }
    if (isDirectWorldChild && c.angle == 0) {
      final w = c.size.x * c.scale.x;
      final h = c.size.y * c.scale.y;
      final l = c.position.x - c.anchor.x * w;
      final t = c.position.y - c.anchor.y * h;
      return Rect.fromLTRB(
        math.min(l, l + w),
        math.min(t, t + h),
        math.max(l, l + w),
        math.max(t, t + h),
      );
    }
    return c.toAbsoluteRect();
  }

  /// Marks membership dirty when children are added, removed, or reconfigured.
  void markMembershipDirty() {
    _dirtyMembership = true;
  }

  void _releaseVisibleBuckets(_RenderPassState state) {
    final buckets = state.visibleByContainer;
    if (buckets.isEmpty) {
      return;
    }
    for (final list in buckets.values) {
      list.clear();
      _bucketPool.add(list);
    }
    buckets.clear();
  }

  List<Component> _acquireBucket(
    _RenderPassState state,
    Component container,
  ) {
    final buckets = state.visibleByContainer;
    final existing = buckets[container];
    if (existing != null) {
      return existing;
    }
    final list = _bucketPool.isNotEmpty
        ? _bucketPool.removeLast()
        : <Component>[];
    buckets[container] = list;
    return list;
  }

  /// Clears all cached entries.
  void clear() {
    _grid.clear();
    _indexedNodes.clear();
    _nodeList.clear();
    _unindexed.clear();
    _pureIndexedContainers.clear();
    _hitSkippableContainers.clear();
    for (final state in _passStates) {
      _releaseVisibleBuckets(state);
      state.visibleNodes.clear();
      state.stamp = 0;
    }
    _indexedCullableCount = 0;
    _renderPassStamp = 0;
    _dirtyMembership = true;
    _lastGlobalTxMutation = -1;
  }

  void _registerLeaf(PositionComponent pc, {required bool isDirectWorldChild}) {
    final node = _IndexedNode(
      component: pc,
      isDirectWorldChild: isDirectWorldChild,
    );
    _indexedNodes[pc] = node;
    _nodeList.add(node);
    if (pc is CullWhenOffscreen) {
      _indexedCullableCount++;
    }
    _updateNodeBounds(node, force: true);
  }

  /// Recursively indexes eligible descendants inside [container], returning
  /// `true` if every child of [container] is either an indexed leaf or a pure
  /// indexed sub-container (allowing `O(visible)` child rendering).
  bool _indexContainerSubtree(Component container) {
    if (!_canDescendIntoContainer(container)) {
      return false;
    }
    var allChildrenPure = true;
    var hitSkippable = _isHitInertContainer(container);
    for (final child in container.children) {
      if (_isEligibleLeafForSpatialGrid(child)) {
        _registerLeaf(child as PositionComponent, isDirectWorldChild: false);
      } else if (_canDescendIntoContainer(child)) {
        final subPure = _indexContainerSubtree(child);
        if (!subPure) {
          allChildrenPure = false;
        }
        if (!_hitSkippableContainers.contains(child)) {
          hitSkippable = false;
        }
      } else {
        allChildrenPure = false;
      }
    }
    if (allChildrenPure) {
      _pureIndexedContainers.add(container);
      if (hitSkippable) {
        _hitSkippableContainers.add(container);
      }
    }
    return allChildrenPure;
  }

  /// Reconciles membership against [children] (and eligible nested layer
  /// subtrees) and updates only AABBs whose local or ancestor `Transform2D`
  /// version or dimensions changed since the previous sync.
  void syncWithChildren(Iterable<Component> children) {
    if (_openPassCount > 0) {
      // A pass is rendering from the nodes and buckets collected at its
      // start (which was preceded by a sync in this very frame). Rebuilding
      // them underneath it would make it drop what it has not drawn yet.
      return;
    }
    if (_dirtyMembership) {
      _dirtyMembership = false;
      _grid.clear();
      _indexedNodes.clear();
      _nodeList.clear();
      _unindexed.clear();
      _pureIndexedContainers.clear();
      _hitSkippableContainers.clear();
      _indexedCullableCount = 0;
      for (final child in children) {
        if (_isEligibleLeafForSpatialGrid(child)) {
          _registerLeaf(child as PositionComponent, isDirectWorldChild: true);
        } else {
          _unindexed.add(child);
          if (_canDescendIntoContainer(child)) {
            _indexContainerSubtree(child);
          }
        }
      }
      _lastGlobalTxMutation = Transform2D.globalMutationCount;
      _syncPassCount++;
      return;
    }

    final globalVer = Transform2D.globalMutationCount;
    if (globalVer == _lastGlobalTxMutation) {
      return;
    }
    _lastGlobalTxMutation = globalVer;
    _syncPassCount++;

    for (var i = 0; i < _nodeList.length; i++) {
      final node = _nodeList[i];
      if (!_isEligibleLeafForSpatialGrid(node.component)) {
        _dirtyMembership = true;
        syncWithChildren(children);
        return;
      }
      _updateNodeBounds(node, force: false);
    }
  }

  void _updateNodeBounds(_IndexedNode node, {required bool force}) {
    final c = node.component;
    final txVer = node.isDirectWorldChild
        ? c.transform.version
        : c.worldTransformVersion;
    final sx = c.size.x;
    final sy = c.size.y;
    final ax = c.anchor.x;
    final ay = c.anchor.y;
    final pad = c is CullWhenOffscreen ? c.cullPadding : 0.0;
    final outset = c is CullWhenOffscreen ? c.cullBoundsOutset : Rect.zero;
    if (!force &&
        node.lastTxVersion == txVer &&
        node.lastSizeX == sx &&
        node.lastSizeY == sy &&
        node.lastAnchorX == ax &&
        node.lastAnchorY == ay &&
        node.lastPadding == pad &&
        node.lastOutset == outset) {
      return;
    }
    node
      ..lastTxVersion = txVer
      ..lastSizeX = sx
      ..lastSizeY = sy
      ..lastAnchorX = ax
      ..lastAnchorY = ay
      ..lastPadding = pad
      ..lastOutset = outset;
    _grid.upsertRect(
      c,
      _computeWorldAabb(c, isDirectWorldChild: node.isDirectWorldChild),
    );
  }

  static int _compareDrawOrder(Component a, Component b) {
    final p = a.priority.compareTo(b.priority);
    if (p != 0) {
      return p;
    }
    final s = a.sortKey.compareTo(b.sortKey);
    if (s != 0) {
      return s;
    }
    return a.parentOrderIndex.compareTo(b.parentOrderIndex);
  }

  static void _shellSortComponents<T extends Component>(
    List<T> list, {
    bool desc = false,
  }) {
    final count = list.length;
    if (count <= 1) {
      return;
    }
    const gaps = <int>[701, 301, 132, 57, 23, 10, 4, 1];
    for (var g = 0; g < gaps.length; g++) {
      final gap = gaps[g];
      if (gap >= count) {
        continue;
      }
      for (var i = gap; i < count; i++) {
        final cur = list[i];
        var j = i;
        while (j >= gap) {
          final prev = list[j - gap];
          final cmp = desc
              ? _compareDrawOrder(cur, prev)
              : _compareDrawOrder(prev, cur);
          if (cmp <= 0) {
            break;
          }
          list[j] = prev;
          j -= gap;
        }
        list[j] = cur;
      }
    }
  }

  /// Internal check used by `Component.renderTree` during a spatial camera pass
  /// to render only the `O(visible)` children of pure-indexed layer containers.
  @internal
  List<Component>? visibleChildrenForPureContainer(Component container) {
    if (!_pureIndexedContainers.contains(container)) {
      return null;
    }
    return _activePass.visibleByContainer[container] ?? const <Component>[];
  }

  /// Internal check used by mixed-child containers to skip offscreen indexed
  /// leaves in `O(1)`.
  @internal
  bool shouldRenderChild(Component child) {
    final node = child is PositionComponent ? _indexedNodes[child] : null;
    if (node == null) {
      return true;
    }
    if (_openPassCount > 1) {
      return _activePass.visibleNodes.contains(node);
    }
    return node.visibleStamp == _passStates[0].stamp;
  }

  /// Populates [out] with all visible direct components overlapping
  /// [visibleWorldRect] plus unindexed fallback containers (while stamping and
  /// bucketing visible nested descendants in `O(visible)`), sorted in exact
  /// forward `(priority, sortKey, parentOrderIndex)` render order.
  ///
  /// Returns `(visibleIndexedCount, visibleCullableCount)`.
  (int visibleIndexed, int visibleCullables) collectVisibleForRender(
    Rect visibleWorldRect,
    List<Component> out, {
    int cameraMask = 0xFFFFFFFF,
  }) {
    out.clear();
    final state = _activePass;
    final nested = _openPassCount > 1;
    _releaseVisibleBuckets(state);
    state.visibleNodes.clear();
    _gridScratch.clear();
    final stamp = ++_renderPassStamp;
    state.stamp = stamp;
    _grid.queryRect(visibleWorldRect, _gridScratch);
    var visibleIndexed = 0;
    var visibleCullables = 0;

    for (var i = 0; i < _gridScratch.length; i++) {
      final comp = _gridScratch[i];
      if ((comp.cameraMask & cameraMask) == 0) {
        continue;
      }
      final node = _indexedNodes[comp];
      if (node == null) {
        continue;
      }
      if (nested) {
        // The stamp on the node belongs to the outermost pass.
        state.visibleNodes.add(node);
      } else {
        node.visibleStamp = stamp;
      }
      visibleIndexed++;
      if (comp is CullWhenOffscreen) {
        comp.markSpatialVisible(stamp);
        visibleCullables++;
      }
      if (node.isDirectWorldChild) {
        out.add(comp);
      } else {
        var cursor = comp as Component;
        var parent = cursor.parent;
        while (parent != null && _pureIndexedContainers.contains(parent)) {
          final bucket = _acquireBucket(state, parent);
          if (identical(cursor, comp) || !bucket.contains(cursor)) {
            bucket.add(cursor);
          }
          cursor = parent;
          parent = cursor.parent;
        }
      }
    }

    for (final bucket in state.visibleByContainer.values) {
      if (bucket.length > 1) {
        _shellSortComponents(bucket);
      }
    }

    for (var i = 0; i < _unindexed.length; i++) {
      final c = _unindexed[i];
      if ((c.cameraMask & cameraMask) != 0) {
        out.add(c);
      }
    }
    _shellSortComponents(out);
    return (visibleIndexed, visibleCullables);
  }

  /// Populates [out] with top-level candidate components at `(x, y)` in reverse
  /// `(priority, sortKey, parentOrderIndex)` hit-test order.
  void collectCandidatesAtPoint(
    double x,
    double y,
    List<Component> out, {
    int cameraMask = 0xFFFFFFFF,
  }) {
    out.clear();
    _gridScratch.clear();
    _grid.queryPoint(x, y, _gridScratch);
    final addedTopLevel = HashSet<Component>.identity();
    for (var i = 0; i < _gridScratch.length; i++) {
      final comp = _gridScratch[i];
      if ((comp.cameraMask & cameraMask) == 0) {
        continue;
      }
      final node = _indexedNodes[comp];
      if (node != null && node.isDirectWorldChild) {
        if (addedTopLevel.add(comp)) {
          out.add(comp);
        }
      } else {
        // Walk up to the direct World child container that owns this hit leaf.
        var top = comp.parent;
        while (top != null && top.parent != null && top.parent is! World) {
          top = top.parent;
        }
        if (top != null &&
            (top.cameraMask & cameraMask) != 0 &&
            addedTopLevel.add(top)) {
          out.add(top);
        }
      }
    }
    for (var i = 0; i < _unindexed.length; i++) {
      final c = _unindexed[i];
      // A container is only left out when it is known that neither it nor
      // any container below it can be hit: then the leaves found above are
      // everything there is to hit inside of it.
      if ((c.cameraMask & cameraMask) != 0 &&
          !_hitSkippableContainers.contains(c) &&
          addedTopLevel.add(c)) {
        out.add(c);
      }
    }
    _shellSortComponents(out, desc: true);
  }

  /// Queries indexed `PositionComponent`s overlapping [bounds] into [out].
  int queryRect(Rect bounds, List<PositionComponent> out) =>
      _grid.queryRect(bounds, out);

  /// Queries indexed `PositionComponent`s overlapping [bounds] into [out],
  /// sorted in forward `(priority, sortKey, parentOrderIndex)` order.
  int queryRectOrdered(Rect bounds, List<PositionComponent> out) {
    final start = out.length;
    final added = _grid.queryRect(bounds, out);
    if (start == 0 && added > 1) {
      _shellSortComponents(out);
    }
    return added;
  }

  /// Queries indexed `PositionComponent`s containing `(x, y)` into [out].
  int queryPoint(double x, double y, List<PositionComponent> out) =>
      _grid.queryPoint(x, y, out);

  /// Queries indexed `PositionComponent`s within [radius] of `(cx, cy)`.
  int queryRadius(
    double cx,
    double cy,
    double radius,
    List<PositionComponent> out,
  ) => _grid.queryRadius(cx, cy, radius, out);
}
