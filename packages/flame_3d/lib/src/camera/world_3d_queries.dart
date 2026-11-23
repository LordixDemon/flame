part of 'world_3d.dart';

extension _World3DQueries on World3D {
  /// Casts [ray] (in world space) against the [Object3D]s of this world
  /// within [maxDistance], returning the closest [RayHit3D] or `null` when
  /// missed.
  ///
  /// Only what a render pass could draw is hit: a [Component3D] that is not
  /// [Component3D.visible], or whose [Component3D.cameraMask] shares no bit
  /// with [cameraMask], is skipped with its whole subtree, as the passes skip
  /// it. The default [cameraMask] matches every object some camera draws;
  /// pass the mask of a camera or of a `Scene3DComponent` to hit only what it
  /// shows. With [includeHidden], every object is tested, whatever its
  /// visibility and camera mask (for collision-like probes against invisible
  /// geometry). [filter], when given, must also accept the object.
  RayHit3D? _raycastImpl(
    Ray ray, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
    int cameraMask = 0xFFFFFFFF,
    bool includeHidden = false,
  }) {
    if (!(maxDistance > 0)) {
      return null;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return null;
    }
    World3D._unitRay.origin.setFrom(ray.origin);
    World3D._unitRay.direction
      ..setFrom(ray.direction)
      ..scale(1.0 / dirLen);

    if (spatialIndex3DEnabled) {
      return spatialIndex3D.raycast(
        this,
        World3D._unitRay,
        maxDistance: maxDistance,
        cullMode: cullMode,
        filter: _indexFilter(filter, cameraMask, includeHidden),
      );
    }

    RayHit3D? best;
    var limit = maxDistance;

    void visit(flame.Component component) {
      if (component is Component3D) {
        if (!includeHidden && !World3D._drawnFor(component, cameraMask)) {
          return;
        }
        if (!rayHitsAabb(World3D._unitRay, component.aabb, limit)) {
          return;
        }
        if (component is Object3D && (filter == null || filter(component))) {
          final hit = component.raycast(
            World3D._unitRay,
            maxDistance: limit,
            cullMode: cullMode,
          );
          if (hit != null && hit.distance < limit) {
            limit = hit.distance;
            best = hit;
          }
        }
      }
      for (final child in component.children) {
        visit(child);
      }
    }

    for (final child in children) {
      visit(child);
    }
    return best;
  }

  /// Casts [ray] against the [Object3D]s of this world within [maxDistance],
  /// returning every hit sorted from nearest to farthest.
  ///
  /// Hidden and masked-out objects are skipped as in [raycast].
  List<RayHit3D> _raycastAllImpl(
    Ray ray, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
    int cameraMask = 0xFFFFFFFF,
    bool includeHidden = false,
  }) {
    final hits = <RayHit3D>[];
    if (!(maxDistance > 0)) {
      return hits;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return hits;
    }
    World3D._unitRay.origin.setFrom(ray.origin);
    World3D._unitRay.direction
      ..setFrom(ray.direction)
      ..scale(1.0 / dirLen);

    if (spatialIndex3DEnabled) {
      return spatialIndex3D.raycastAll(
        this,
        World3D._unitRay,
        maxDistance: maxDistance,
        cullMode: cullMode,
        filter: _indexFilter(filter, cameraMask, includeHidden),
      );
    }

    void visit(flame.Component component) {
      if (component is Component3D) {
        if (!includeHidden && !World3D._drawnFor(component, cameraMask)) {
          return;
        }
        if (!rayHitsAabb(World3D._unitRay, component.aabb, maxDistance)) {
          return;
        }
        if (component is Object3D && (filter == null || filter(component))) {
          final hit = component.raycast(
            World3D._unitRay,
            maxDistance: maxDistance,
            cullMode: cullMode,
          );
          if (hit != null) {
            hits.add(hit);
          }
        }
      }
      for (final child in component.children) {
        visit(child);
      }
    }

    for (final child in children) {
      visit(child);
    }
    hits.sort((a, b) => a.distance.compareTo(b.distance));
    return hits;
  }

  /// The filter of an indexed ray cast: the index holds every [Object3D]
  /// flat, so the visibility and masks of the ancestors are checked here.
  bool Function(Object3D object)? _indexFilter(
    bool Function(Object3D object)? filter,
    int cameraMask,
    bool includeHidden,
  ) {
    if (includeHidden) {
      return filter;
    }
    return (object) {
      flame.Component? cursor = object;
      while (cursor != null && !identical(cursor, this)) {
        if (cursor is Component3D && !World3D._drawnFor(cursor, cameraMask)) {
          return false;
        }
        cursor = cursor.parent;
      }
      return filter == null || filter(object);
    };
  }
}
