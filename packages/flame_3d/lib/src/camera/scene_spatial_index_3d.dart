import 'dart:collection' show UnmodifiableListView;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:meta/meta.dart';

/// Incremental dynamic AABB Bounding Volume Hierarchy (BVH) over the
/// [Object3D]s of a [World3D], backed by [DynamicAabbTree3D].
///
/// Updates incrementally via [onObjectAdded], [onObjectRemoved], and
/// [onObjectMoved] hooks from [Component3D], accelerating world-space AABB
/// queries, camera frustum queries, and front-to-back distance-pruned
/// `World3D.raycast` / `raycastAll` from `O(N)` to `O(log N)`.
class SceneSpatialIndex3D() {
  final DynamicAabbTree3D<Object3D> _tree = DynamicAabbTree3D<Object3D>();
  final Map<Object3D, int> _proxies = Map.identity();
  final List<Object3D> _dirtyObjects = <Object3D>[];
  final List<Object3D> _candidateScratch = <Object3D>[];

  World3D? _boundWorld;
  bool _initialized = false;
  int _builtComponentsVersion = -1;
  int _fullRebuildCount = 0;
  int _incrementalUpdateCount = 0;

  /// Number of indexed [Object3D]s currently registered in this BVH.
  int get indexedObjectCount => _proxies.length;

  /// Number of active BVH nodes in the underlying [DynamicAabbTree3D].
  int get nodeCount => _tree.nodeCount;

  /// Number of full scene tree rebuilds performed since creation.
  int get fullRebuildCount => _fullRebuildCount;

  /// Number of incremental add, remove, or move operations applied without a
  /// full scene rebuild.
  int get incrementalUpdateCount => _incrementalUpdateCount;

  /// Number of narrowphase `Object3D.raycast` tests executed by the last
  /// [raycast] or [raycastAll] call.
  int lastRaycastCandidatesTested = 0;

  /// Marks the index out of date so the next query rebuilds it from scratch.
  void invalidate() {
    _initialized = false;
    _boundWorld = null;
    _builtComponentsVersion = -1;
    for (var i = 0; i < _dirtyObjects.length; i++) {
      _dirtyObjects[i].spatialIndexDirty = false;
    }
    _dirtyObjects.clear();
  }

  /// Incrementally inserts [object] when this index has already been built.
  @internal
  void onObjectAdded(Object3D object) {
    if (!_initialized) {
      return;
    }
    object.spatialIndexDirty = false;
    final existing = _proxies[object];
    if (existing != null) {
      _tree.update(existing, object.aabb);
    } else {
      _proxies[object] = _tree.insert(object, object.aabb);
    }
    _incrementalUpdateCount++;
  }

  /// Incrementally removes [object] when this index has already been built.
  @internal
  void onObjectRemoved(Object3D object) {
    object.spatialIndexDirty = false;
    if (!_initialized) {
      return;
    }
    final proxyId = _proxies.remove(object);
    if (proxyId != null) {
      _tree.remove(proxyId);
      _incrementalUpdateCount++;
    }
  }

  /// Queues [object] for an incremental fat-AABB update before the next query.
  @internal
  void onObjectMoved(Object3D object) {
    if (!_initialized ||
        object.spatialIndexDirty ||
        !_proxies.containsKey(object)) {
      return;
    }
    object.spatialIndexDirty = true;
    _dirtyObjects.add(object);
  }

  /// Ensures the BVH is up to date for [world].
  void ensureBuilt(World3D world) {
    if (!_initialized ||
        !identical(_boundWorld, world) ||
        (!world.isMounted &&
            _builtComponentsVersion != world.componentsVersion)) {
      _rebuild(world);
      _initialized = true;
      _boundWorld = world;
      _builtComponentsVersion = world.componentsVersion;
      _fullRebuildCount++;
      return;
    }

    if (_dirtyObjects.isNotEmpty) {
      for (var i = 0; i < _dirtyObjects.length; i++) {
        final obj = _dirtyObjects[i];
        obj.spatialIndexDirty = false;
        final proxyId = _proxies[obj];
        if (proxyId != null && obj.isMounted) {
          _tree.update(proxyId, obj.aabb);
          _incrementalUpdateCount++;
        }
      }
      _dirtyObjects.clear();
    }
    _builtComponentsVersion = world.componentsVersion;
  }

  void _rebuild(World3D world) {
    _tree.clear();
    _proxies.clear();
    for (var i = 0; i < _dirtyObjects.length; i++) {
      _dirtyObjects[i].spatialIndexDirty = false;
    }
    _dirtyObjects.clear();

    void collect(Component3D parent) {
      for (final child in parent.children) {
        if (child is Object3D) {
          _proxies[child] = _tree.insert(child, child.aabb);
        }
        if (child is Component3D) {
          collect(child);
        }
      }
    }

    for (final child in world.children) {
      if (child is Object3D) {
        _proxies[child] = _tree.insert(child, child.aabb);
      }
      if (child is Component3D) {
        collect(child);
      }
    }
  }

  /// Appends every [Object3D] whose tight world AABB overlaps [bounds] into
  /// [out].
  List<Object3D> queryAabb(
    World3D world,
    Aabb3 bounds, {
    List<Object3D>? out,
  }) {
    final result = out ?? <Object3D>[];
    ensureBuilt(world);
    if (_proxies.isEmpty) {
      return result;
    }
    _candidateScratch.clear();
    _tree.queryAabb(bounds, out: _candidateScratch);
    final qMin = bounds.min;
    final qMax = bounds.max;
    for (var i = 0; i < _candidateScratch.length; i++) {
      final obj = _candidateScratch[i];
      final b = obj.aabb;
      if (b.max.x >= qMin.x &&
          b.min.x <= qMax.x &&
          b.max.y >= qMin.y &&
          b.min.y <= qMax.y &&
          b.max.z >= qMin.z &&
          b.min.z <= qMax.z) {
        result.add(obj);
      }
    }
    return result;
  }

  /// Appends every [Object3D] whose tight world AABB intersects [frustum] into
  /// [out].
  List<Object3D> queryFrustum(
    World3D world,
    Frustum frustum, {
    List<Object3D>? out,
  }) {
    final result = out ?? <Object3D>[];
    ensureBuilt(world);
    if (_proxies.isEmpty) {
      return result;
    }
    _candidateScratch.clear();
    _tree.queryFrustum(frustum, out: _candidateScratch);
    for (var i = 0; i < _candidateScratch.length; i++) {
      final obj = _candidateScratch[i];
      if (frustum.intersectsWithAabb3(obj.aabb)) {
        result.add(obj);
      }
    }
    return result;
  }

  CullMode? _activeCullMode;
  bool Function(Object3D object)? _activeUserFilter;
  double _bestHitDistance = double.infinity;
  RayHit3D? _bestRayHit;
  List<RayHit3D>? _activeHitsOut;
  double _activeInvDx = 0.0;
  double _activeInvDy = 0.0;
  double _activeInvDz = 0.0;
  double _activeOx = 0.0;
  double _activeOy = 0.0;
  double _activeOz = 0.0;

  late final (double, Vector3?)? Function(Object3D, Ray, double)
  _raycastNarrowphaseCb = _onRaycastLeaf;
  late final (double, Vector3?)? Function(Object3D, Ray, double)
  _raycastAllNarrowphaseCb = _onRaycastAllLeaf;
  late final bool Function(Object3D) _filterCb = _onFilterLeaf;

  bool _onFilterLeaf(Object3D obj) => _activeUserFilter!(obj);

  (double, Vector3?)? _onRaycastLeaf(
    Object3D obj,
    Ray unitRay,
    double maxDist,
  ) {
    final tObj = _intersectTightAabb(obj.aabb, maxDist);
    if (!tObj.isFinite || tObj > maxDist) {
      return null;
    }
    lastRaycastCandidatesTested++;
    final hit = obj.raycast(
      unitRay,
      maxDistance: maxDist,
      cullMode: _activeCullMode,
    );
    if (hit != null && hit.distance < _bestHitDistance) {
      _bestHitDistance = hit.distance;
      _bestRayHit = hit;
      return (hit.distance, null);
    }
    return null;
  }

  (double, Vector3?)? _onRaycastAllLeaf(
    Object3D obj,
    Ray unitRay,
    double maxDist,
  ) {
    final tObj = _intersectTightAabb(obj.aabb, maxDist);
    if (!tObj.isFinite || tObj > maxDist) {
      return null;
    }
    lastRaycastCandidatesTested++;
    final hit = obj.raycast(
      unitRay,
      maxDistance: maxDist,
      cullMode: _activeCullMode,
    );
    if (hit != null) {
      _activeHitsOut!.add(hit);
    }
    return null;
  }

  /// Closest narrowphase triangle hit along [worldRay], traversing BVH nodes
  /// front-to-back and pruning subtrees beyond the closest hit distance.
  RayHit3D? raycast(
    World3D world,
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
  }) {
    lastRaycastCandidatesTested = 0;
    ensureBuilt(world);
    if (_proxies.isEmpty) {
      return null;
    }

    final dirLen = worldRay.direction.length;
    if (dirLen <= 1e-12) {
      return null;
    }
    final invLen = 1.0 / dirLen;
    _activeOx = worldRay.origin.x;
    _activeOy = worldRay.origin.y;
    _activeOz = worldRay.origin.z;
    _activeInvDx = 1.0 / (worldRay.direction.x * invLen);
    _activeInvDy = 1.0 / (worldRay.direction.y * invLen);
    _activeInvDz = 1.0 / (worldRay.direction.z * invLen);
    _activeCullMode = cullMode;
    _activeUserFilter = filter;
    _bestHitDistance = maxDistance;
    _bestRayHit = null;

    _tree.raycast(
      worldRay,
      maxDistance: maxDistance,
      narrowphase: _raycastNarrowphaseCb,
      filter: filter != null ? _filterCb : null,
    );
    final result = _bestRayHit;
    _bestRayHit = null;
    _activeUserFilter = null;
    return result;
  }

  /// All narrowphase hits along [worldRay] up to [maxDistance], sorted by
  /// ascending hit distance.
  List<RayHit3D> raycastAll(
    World3D world,
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
  }) {
    lastRaycastCandidatesTested = 0;
    final hits = <RayHit3D>[];
    ensureBuilt(world);
    if (_proxies.isEmpty) {
      return hits;
    }

    final dirLen = worldRay.direction.length;
    if (dirLen <= 1e-12) {
      return hits;
    }
    final invLen = 1.0 / dirLen;
    _activeOx = worldRay.origin.x;
    _activeOy = worldRay.origin.y;
    _activeOz = worldRay.origin.z;
    _activeInvDx = 1.0 / (worldRay.direction.x * invLen);
    _activeInvDy = 1.0 / (worldRay.direction.y * invLen);
    _activeInvDz = 1.0 / (worldRay.direction.z * invLen);
    _activeCullMode = cullMode;
    _activeUserFilter = filter;
    _activeHitsOut = hits;

    _tree.raycastAll(
      worldRay,
      maxDistance: maxDistance,
      narrowphase: _raycastAllNarrowphaseCb,
      filter: filter != null ? _filterCb : null,
    );
    _activeHitsOut = null;
    _activeUserFilter = null;
    hits.sort((a, b) => a.distance.compareTo(b.distance));
    return UnmodifiableListView<RayHit3D>(hits);
  }

  double _intersectTightAabb(Aabb3 box, double maxDist) {
    const pad = 1e-5;
    final min = box.min;
    final max = box.max;
    var tMin = double.negativeInfinity;
    var tMax = double.infinity;

    for (var axis = 0; axis < 3; axis++) {
      final origin = axis == 0
          ? _activeOx
          : (axis == 1 ? _activeOy : _activeOz);
      final inv = axis == 0
          ? _activeInvDx
          : (axis == 1 ? _activeInvDy : _activeInvDz);
      final lo = (axis == 0 ? min.x : (axis == 1 ? min.y : min.z)) - pad;
      final hi = (axis == 0 ? max.x : (axis == 1 ? max.y : max.z)) + pad;
      if (inv.isInfinite) {
        if (origin < lo || origin > hi) {
          return double.infinity;
        }
        continue;
      }
      final t1 = (lo - origin) * inv;
      final t2 = (hi - origin) * inv;
      final near = t1 < t2 ? t1 : t2;
      final far = t1 > t2 ? t1 : t2;
      if (near > tMin) {
        tMin = near;
      }
      if (far < tMax) {
        tMax = far;
      }
    }

    if (tMax < 0 || tMin > tMax || tMin > maxDist) {
      return double.infinity;
    }
    return tMin < 0 ? 0.0 : tMin;
  }
}
