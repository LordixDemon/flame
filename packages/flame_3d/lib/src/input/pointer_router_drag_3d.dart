part of 'pointer_router_3d.dart';

extension _PointerRouterDrag on PointerRouter3D {
  bool _dispatchDragStartImpl(Vector2 point, {int pointerId = 0}) {
    _lastPointerPositions[pointerId] = point.clone();
    final (ray, hit) = _pick(point);
    if (hit == null) {
      _activeDrags.remove(pointerId);
      return false;
    }

    final capturedInstance = hit.instanceIndex;
    final entries = <_DragListenerEntry>[];

    for (final node in PointerRouter3D._selfAndAncestors(hit.object)) {
      if (node is DragCallbacks3D) {
        final entry = _buildDragEntry(node, ray, hit.worldPoint);
        final startEvent = DragStartEvent3D(
          pointerId: pointerId,
          localPosition: point.clone(),
          worldRay: Ray.copy(ray),
          target: hit.object,
          hit: hit,
          instanceIndex: capturedInstance,
          worldPlanePoint: entry.lastPlanePoint.clone(),
        );
        entries.add(entry);
        node.onDragStart3D(startEvent);
        if (startEvent.handled) {
          break;
        }
      }
    }

    if (entries.isEmpty) {
      _activeDrags.remove(pointerId);
      return false;
    }

    _activeDrags[pointerId] = _ActiveDragState(
      target: hit.object,
      instanceIndex: capturedInstance,
      lastLocalPoint: point.clone(),
      lastRay: Ray.copy(ray),
      entries: entries,
    );
    return true;
  }

  bool _dispatchDragUpdateImpl(Vector2 point, {int pointerId = 0}) {
    _lastPointerPositions[pointerId] = point.clone();
    final active = _activeDrags[pointerId];
    if (active == null) {
      return false;
    }

    final ray = pointToWorldRay(point);
    active
      ..lastLocalPoint = point.clone()
      ..lastRay = Ray.copy(ray);

    for (final entry in active.entries) {
      final nextPoint = entry.projectRay(ray, isPerspective: _isPerspective);
      final delta = nextPoint - entry.lastPlanePoint;
      entry.lastPlanePoint.setFrom(nextPoint);

      final updateEvent = DragUpdateEvent3D(
        pointerId: pointerId,
        localPosition: point.clone(),
        worldRay: Ray.copy(ray),
        target: active.target,
        instanceIndex: active.instanceIndex,
        worldPlanePoint: nextPoint.clone(),
        worldDelta: delta,
      );
      entry.listener.onDragUpdate3D(updateEvent);
      if (updateEvent.handled) {
        break;
      }
    }
    return true;
  }

  bool _dispatchDragEndImpl({
    int pointerId = 0,
    Vector2? point,
    bool wasCancelled = false,
  }) {
    final active = _activeDrags.remove(pointerId);
    if (active == null) {
      return false;
    }

    final pos = point?.clone() ?? active.lastLocalPoint.clone();
    final ray = point != null ? pointToWorldRay(point) : active.lastRay;

    for (final entry in active.entries) {
      final finalPoint = point != null
          ? entry.projectRay(ray, isPerspective: _isPerspective)
          : entry.lastPlanePoint.clone();
      final delta = finalPoint - entry.lastPlanePoint;

      final endEvent = DragEndEvent3D(
        pointerId: pointerId,
        localPosition: pos.clone(),
        worldRay: Ray.copy(ray),
        target: active.target,
        instanceIndex: active.instanceIndex,
        worldPlanePoint: finalPoint,
        worldDelta: delta,
        wasCancelled: wasCancelled,
      );
      entry.listener.onDragEnd3D(endEvent);
      if (endEvent.handled) {
        break;
      }
    }
    return true;
  }

  _DragListenerEntry _buildDragEntry(
    DragCallbacks3D listener,
    Ray startRay,
    Vector3 grabPoint,
  ) {
    final axis = listener.dragAxisConstraint;
    if (axis != null && axis.length2 > 1e-12) {
      final unitAxis = axis.normalized();
      final initialS =
          closestRayAxisParam3D(
            grabPoint,
            unitAxis,
            startRay.origin,
            startRay.direction,
          ) ??
          0.0;
      return _DragListenerEntry.axis(
        listener: listener,
        anchorPoint: grabPoint.clone(),
        unitAxis: unitAxis,
        initialAxisParam: initialS,
      );
    }

    final planeNormal = _resolvePlaneNormal(listener, startRay);
    return _DragListenerEntry.plane(
      listener: listener,
      anchorPoint: grabPoint.clone(),
      planeNormal: planeNormal,
    );
  }

  Vector3 _resolvePlaneNormal(DragCallbacks3D listener, Ray ray) {
    final explicit = listener.dragPlaneNormal;
    if (explicit != null && explicit.length2 > 1e-12) {
      return explicit.normalized();
    }
    final fallback = defaultDragNormal;
    if (fallback != null && fallback.length2 > 1e-12) {
      return fallback.normalized();
    }
    if (_camera case final camera?) {
      final viewBack = camera.position - camera.target;
      if (viewBack.length2 > 1e-12) {
        return viewBack..normalize();
      }
    }
    if (ray.direction.length2 > 1e-12) {
      return (-ray.direction)..normalize();
    }
    return Vector3(0, 1, 0);
  }
}

class _ActiveDragState({
  required final Object3D target,
  required final int? instanceIndex,
  required var Vector2 lastLocalPoint,
  required var Ray lastRay,
  required final List<_DragListenerEntry> entries,
});

class _DragListenerEntry._({
  required final DragCallbacks3D listener,
  required final Vector3 anchorPoint,
  required final Vector3 lastPlanePoint,
  final Vector3? planeNormal,
  final Vector3? unitAxis,
  final double initialAxisParam = 0.0,
}) {
  factory _DragListenerEntry.plane({
    required DragCallbacks3D listener,
    required Vector3 anchorPoint,
    required Vector3 planeNormal,
  }) {
    return _DragListenerEntry._(
      listener: listener,
      anchorPoint: anchorPoint,
      lastPlanePoint: anchorPoint.clone(),
      planeNormal: planeNormal,
    );
  }

  factory _DragListenerEntry.axis({
    required DragCallbacks3D listener,
    required Vector3 anchorPoint,
    required Vector3 unitAxis,
    required double initialAxisParam,
  }) {
    return _DragListenerEntry._(
      listener: listener,
      anchorPoint: anchorPoint,
      lastPlanePoint: anchorPoint.clone(),
      unitAxis: unitAxis,
      initialAxisParam: initialAxisParam,
    );
  }

  Vector3 projectRay(Ray ray, {required bool isPerspective}) {
    if (unitAxis case final axis?) {
      final s = closestRayAxisParam3D(
        anchorPoint,
        axis,
        ray.origin,
        ray.direction,
      );
      if (s == null) {
        return lastPlanePoint.clone();
      }
      final deltaS = s - initialAxisParam;
      return Vector3(
        anchorPoint.x + axis.x * deltaS,
        anchorPoint.y + axis.y * deltaS,
        anchorPoint.z + axis.z * deltaS,
      );
    }

    final n = planeNormal!;
    final denom =
        n.x * ray.direction.x + n.y * ray.direction.y + n.z * ray.direction.z;
    if (denom.abs() <= 1e-8) {
      return lastPlanePoint.clone();
    }
    final diffX = anchorPoint.x - ray.origin.x;
    final diffY = anchorPoint.y - ray.origin.y;
    final diffZ = anchorPoint.z - ray.origin.z;
    final t = (diffX * n.x + diffY * n.y + diffZ * n.z) / denom;
    if (isPerspective && t < 0.0) {
      return lastPlanePoint.clone();
    }
    return Vector3(
      ray.origin.x + ray.direction.x * t,
      ray.origin.y + ray.direction.y * t,
      ray.origin.z + ray.direction.z * t,
    );
  }
}
