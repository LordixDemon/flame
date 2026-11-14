import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/cull_when_offscreen.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/game/transform2d.dart';
import 'package:flame/src/geometry/spatial_grid_2d.dart';

class _IndexedNode({
  required final PositionComponent component,
}) {
  int lastTxVersion = -1;
  double lastSizeX = double.nan;
  double lastSizeY = double.nan;
  double lastAnchorX = double.nan;
  double lastAnchorY = double.nan;
  double lastPadding = double.nan;
  Rect lastOutset = Rect.zero;
}

/// Native `SpatialGrid2D`-backed spatial index for `World`, accelerating camera
/// frustum culling from `O(N)` to `O(visible)` and 2D point hit-testing from
/// `O(N)` to `O(1)` while preserving exact `(priority, sortKey, mountOrder)`
/// draw and input ordering.
class WorldSpatialIndex({
  double cellSize = 256.0,
  final int initialCapacity = 128,
}) {
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
  final List<PositionComponent> _gridScratch = <PositionComponent>[];

  int _lastGlobalTxMutation = -1;
  bool _dirtyMembership = true;
  int _syncPassCount = 0;
  int _indexedCullableCount = 0;
  int _renderPassStamp = 0;

  /// Active spatial grid cell size in world units.
  double get cellSize => _cellSize;

  /// Number of spatial-grid indexed `PositionComponent`s.
  int get indexedCount => _nodeList.length;

  /// Number of non-spatial fallback components always visited.
  int get unindexedCount => _unindexed.length;

  /// Number of indexed components mixing in [CullWhenOffscreen].
  int get indexedCullableCount => _indexedCullableCount;

  /// Number of AABB synchronization sweeps executed (for testing stationary
  /// `O(1)` skip behavior).
  int get syncPassCount => _syncPassCount;

  /// Monotonically increasing stamp for the latest [collectVisibleForRender].
  int get renderPassStamp => _renderPassStamp;

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

  static bool _isEligibleForSpatialGrid(Component child) {
    if (child is! PositionComponent) {
      return false;
    }
    if (child is CullWhenOffscreen) {
      return child.cullingEnabled;
    }
    return !child.hasChildren && child.size.x > 0 && child.size.y > 0;
  }

  static Rect _computeWorldAabb(PositionComponent c) {
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
    if (c.angle == 0) {
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

  /// Clears all cached entries.
  void clear() {
    _grid.clear();
    _indexedNodes.clear();
    _nodeList.clear();
    _unindexed.clear();
    _indexedCullableCount = 0;
    _renderPassStamp = 0;
    _dirtyMembership = true;
    _lastGlobalTxMutation = -1;
  }

  /// Reconciles membership against [children] and updates only AABBs whose
  /// `Transform2D.version` or dimensions changed since the previous sync.
  void syncWithChildren(Iterable<Component> children) {
    if (_dirtyMembership) {
      _dirtyMembership = false;
      _grid.clear();
      _indexedNodes.clear();
      _nodeList.clear();
      _unindexed.clear();
      _indexedCullableCount = 0;
      for (final child in children) {
        if (_isEligibleForSpatialGrid(child)) {
          final pc = child as PositionComponent;
          final node = _IndexedNode(component: pc);
          _indexedNodes[pc] = node;
          _nodeList.add(node);
          if (pc is CullWhenOffscreen) {
            _indexedCullableCount++;
          }
          _updateNodeBounds(node, force: true);
        } else {
          _unindexed.add(child);
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
      if (!_isEligibleForSpatialGrid(node.component)) {
        _dirtyMembership = true;
        syncWithChildren(children);
        return;
      }
      _updateNodeBounds(node, force: false);
    }
  }

  void _updateNodeBounds(_IndexedNode node, {required bool force}) {
    final c = node.component;
    final txVer = c.transform.version;
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
    _grid.upsertRect(c, _computeWorldAabb(c));
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

  /// Populates [out] with all visible indexed components overlapping
  /// [visibleWorldRect] plus unindexed fallback components, sorted in exact
  /// forward `(priority, sortKey, parentOrderIndex)` render order.
  ///
  /// Returns `(visibleIndexedCount, visibleCullableCount)`.
  (int visibleIndexed, int visibleCullables) collectVisibleForRender(
    Rect visibleWorldRect,
    List<Component> out,
  ) {
    out.clear();
    _gridScratch.clear();
    final stamp = ++_renderPassStamp;
    _grid.queryRect(visibleWorldRect, _gridScratch);
    var visibleCullables = 0;
    for (var i = 0; i < _gridScratch.length; i++) {
      final comp = _gridScratch[i];
      if (comp is CullWhenOffscreen) {
        comp.markSpatialVisible(stamp);
        visibleCullables++;
      }
      out.add(comp);
    }
    final visibleIndexed = _gridScratch.length;
    for (var i = 0; i < _unindexed.length; i++) {
      out.add(_unindexed[i]);
    }
    _shellSortComponents(out);
    return (visibleIndexed, visibleCullables);
  }

  /// Populates [out] with candidate components at `(x, y)` in reverse
  /// `(priority, sortKey, parentOrderIndex)` hit-test order.
  void collectCandidatesAtPoint(double x, double y, List<Component> out) {
    out.clear();
    _gridScratch.clear();
    _grid.queryPoint(x, y, _gridScratch);
    for (var i = 0; i < _gridScratch.length; i++) {
      out.add(_gridScratch[i]);
    }
    for (var i = 0; i < _unindexed.length; i++) {
      out.add(_unindexed[i]);
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
