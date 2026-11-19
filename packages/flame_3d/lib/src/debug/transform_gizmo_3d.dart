import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart' show Ray;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/debug/debug_renderer_3d.dart';

/// Active manipulation tool mode of a [TransformGizmo3D].
enum GizmoMode3D() {
  /// Translates along single axes (`x`, `y`, `z`) or dual-axis planes
  /// (`xy`, `xz`, `yz`).
  translate,

  /// Rotates around orthogonal tangent rings (`x`, `y`, `z`).
  rotate,

  /// Scales along single axes (`x`, `y`, `z`), dual-axis planes, or uniformly
  /// (`xyz`).
  scale,
}

/// Reference coordinate frame of a [TransformGizmo3D].
enum GizmoSpace3D() {
  /// Aligns handles with global world `+X`, `+Y`, `+Z` axes.
  world,

  /// Aligns handles with the selected component's local basis axes.
  local,
}

/// Interactive handle identifier on a [TransformGizmo3D].
enum GizmoAxis3D() {
  /// No handle selected or hovered.
  none,

  /// Single `+X` axis handle.
  x,

  /// Single `+Y` axis handle.
  y,

  /// Single `+Z` axis handle.
  z,

  /// Dual-axis `XY` plane handle (normal `+Z`).
  xy,

  /// Dual-axis `XZ` plane handle (normal `+Y`).
  xz,

  /// Dual-axis `YZ` plane handle (normal `+X`).
  yz,

  /// Center uniform `XYZ` handle.
  xyz,
}

/// Immutable local TRS (`position`, `rotation`, `scale`) snapshot of a
/// [Component3D].
class TransformSnapshot3D({
  required Vector3 position,
  required Quaternion rotation,
  required Vector3 scale,
}) {
  /// Captures the current local TRS state of [component].
  factory TransformSnapshot3D.fromComponent(Component3D component) {
    return TransformSnapshot3D(
      position: component.position,
      rotation: component.rotation,
      scale: component.scale,
    );
  }

  /// Captured local translation.
  final Vector3 position = position.clone();

  /// Captured local rotation quaternion.
  final Quaternion rotation = rotation.clone();

  /// Captured local scale.
  final Vector3 scale = scale.clone();

  /// Restores this snapshot onto [target].
  void applyTo(Component3D target) {
    target.position.setFrom(position);
    target.rotation.setFrom(rotation);
    target.scale.setFrom(scale);
  }

  /// Whether [other] matches this TRS snapshot within [epsilon].
  bool closeTo(TransformSnapshot3D other, {double epsilon = 1e-6}) {
    final posClose =
        (position.x - other.position.x).abs() <= epsilon &&
        (position.y - other.position.y).abs() <= epsilon &&
        (position.z - other.position.z).abs() <= epsilon;
    final sclClose =
        (scale.x - other.scale.x).abs() <= epsilon &&
        (scale.y - other.scale.y).abs() <= epsilon &&
        (scale.z - other.scale.z).abs() <= epsilon;
    bool quatClose(double sign) =>
        (rotation.x - sign * other.rotation.x).abs() <= epsilon &&
        (rotation.y - sign * other.rotation.y).abs() <= epsilon &&
        (rotation.z - sign * other.rotation.z).abs() <= epsilon &&
        (rotation.w - sign * other.rotation.w).abs() <= epsilon;
    return posClose && sclClose && (quatClose(1) || quatClose(-1));
  }
}

/// Reversible TRS edit command stored in [GizmoCommandHistory3D].
class const GizmoTransformCommand3D({
  required final Component3D target,
  required final TransformSnapshot3D before,
  required final TransformSnapshot3D after,
});

/// Bounded undo/redo command stack for [TransformGizmo3D] manipulations.
class GizmoCommandHistory3D({
  final int maxEntries = 128,
}) {
  final List<GizmoTransformCommand3D> _undoStack = [];
  final List<GizmoTransformCommand3D> _redoStack = [];

  /// Whether at least one command can be undone.
  bool get canUndo => _undoStack.isNotEmpty;

  /// Whether at least one undone command can be redone.
  bool get canRedo => _redoStack.isNotEmpty;

  /// Number of commands currently on the undo stack.
  int get undoCount => _undoStack.length;

  /// Number of commands currently on the redo stack.
  int get redoCount => _redoStack.length;

  /// Records a completed transform edit on [target] when [before] and [after]
  /// differ, clearing the redo stack.
  bool record(
    Component3D target, {
    required TransformSnapshot3D before,
    required TransformSnapshot3D after,
  }) {
    if (before.closeTo(after)) {
      return false;
    }
    if (_undoStack.length >= maxEntries && maxEntries > 0) {
      _undoStack.removeAt(0);
    }
    if (maxEntries > 0) {
      _undoStack.add(
        GizmoTransformCommand3D(target: target, before: before, after: after),
      );
    }
    _redoStack.clear();
    return true;
  }

  /// Reverts the most recent transform command, returning `true` if applied.
  bool undo() {
    if (_undoStack.isEmpty) {
      return false;
    }
    final cmd = _undoStack.removeLast();
    cmd.before.applyTo(cmd.target);
    _redoStack.add(cmd);
    return true;
  }

  /// Re-applies the most recently undone transform command, returning `true` if
  /// applied.
  bool redo() {
    if (_redoStack.isEmpty) {
      return false;
    }
    final cmd = _redoStack.removeLast();
    cmd.after.applyTo(cmd.target);
    _undoStack.add(cmd);
    return true;
  }

  /// Clears both undo and redo stacks.
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}

/// Interactive runtime 3D transform gizmo (`translate`, `rotate`, `scale`)
/// rendered via [DebugRenderer3D] with constant-screen-size distance scaling,
/// analytical 3D ray picking, grid/angle/scale snapping, and undo/redo history.
///
/// It is not a component and nothing routes pointer events to it: the game
/// turns pointer positions into rays (for instance with
/// `CameraComponent3D.viewportPointToRay`) and calls [pickHandle],
/// [updateHover], [beginDrag], [updateDrag] and [endDrag] itself, and asks it
/// to draw into a [DebugRenderer3D].
class TransformGizmo3D({
  var Component3D? target,
  var GizmoMode3D mode = GizmoMode3D.translate,
  var GizmoSpace3D space = GizmoSpace3D.world,
  var bool enabled = true,
  var double baseSize = 1.0,
  var double screenScaleFactor = 0.18,
  var double minWorldSize = 0.15,
  var double maxWorldSize = 50.0,
  var double? fixedWorldSize,
  var double? translateSnap,
  var double? rotateSnapRadians,
  var double? scaleSnap,
  GizmoCommandHistory3D? history,
}) {
  /// Undo/redo command history recording completed gizmo drags.
  final GizmoCommandHistory3D history = history ?? GizmoCommandHistory3D();

  static const Color _colorX = Color(0xFFEF4444);
  static const Color _colorY = Color(0xFF22C55E);
  static const Color _colorZ = Color(0xFF3B82F6);
  static const Color _colorXY = Color(0xFF60A5FA);
  static const Color _colorXZ = Color(0xFF4ADE80);
  static const Color _colorYZ = Color(0xFFF87171);
  static const Color _colorCenter = Color(0xFFF8FAFC);
  static const Color _colorActive = Color(0xFFFACC15);

  GizmoAxis3D _hoveredAxis = GizmoAxis3D.none;
  GizmoAxis3D _activeAxis = GizmoAxis3D.none;
  bool _isDragging = false;
  Vector3? _lastCameraPosition;

  // Captured state at drag start.
  TransformSnapshot3D? _dragStartSnapshot;
  final Vector3 _dragStartWorldOrigin = Vector3.zero();
  final Vector3 _dragAxisX = Vector3(1, 0, 0);
  final Vector3 _dragAxisY = Vector3(0, 1, 0);
  final Vector3 _dragAxisZ = Vector3(0, 0, 1);
  final Matrix4 _dragParentInverse = Matrix4.identity();
  final Quaternion _dragParentWorldRot = Quaternion.identity();
  final Quaternion _dragParentWorldRotInv = Quaternion.identity();
  double _dragGizmoScale = 1.0;

  double _dragStartAxisParam = 0.0;
  final Vector3 _dragStartPlanePoint = Vector3.zero();
  final Vector3 _dragPlaneNormal = Vector3(0, 1, 0);
  final Vector3 _dragStartRingRadial = Vector3(1, 0, 0);
  final Vector3 _dragRingAxis = Vector3(0, 1, 0);
  final Vector3 _dragUniformDir = Vector3(1, 0, 0);
  bool _dragRingEdgeOn = false;

  /// Currently hovered handle (`GizmoAxis3D.none` when idle).
  GizmoAxis3D get hoveredAxis => _hoveredAxis;

  /// Handle currently being dragged (`GizmoAxis3D.none` when not dragging).
  GizmoAxis3D get activeAxis => _activeAxis;

  /// Whether an interactive drag session is currently active.
  bool get isDragging => _isDragging;

  /// Last camera eye position supplied to [render] or [cameraPosition].
  Vector3? get cameraPosition => _lastCameraPosition;
  set cameraPosition(Vector3? value) {
    _lastCameraPosition = value?.clone();
  }

  /// Computes the world-space handle radius for the active [target] so the
  /// gizmo maintains a constant apparent screen size across camera distances.
  double computeGizmoScale([Vector3? cameraPosition]) {
    if (fixedWorldSize case final fixed?) {
      return fixed;
    }
    final activeTarget = target;
    final camPos = cameraPosition ?? _lastCameraPosition;
    if (activeTarget == null || camPos == null) {
      return baseSize;
    }
    final origin = _worldOriginOf(activeTarget);
    final dist = origin.distanceTo(camPos);
    return (dist * screenScaleFactor).clamp(minWorldSize, maxWorldSize);
  }

  /// Updates [hoveredAxis] by testing [ray] against the current gizmo handles.
  GizmoAxis3D updateHover(Ray ray, {Vector3? cameraPosition}) {
    final picked = pickHandle(ray, cameraPosition: cameraPosition);
    _hoveredAxis = picked;
    return picked;
  }

  /// Emits all wireframe/handle primitives for the current [mode] into
  /// [renderer], as custom segments that stay until
  /// [DebugRenderer3D.clearCustomSegments].
  void render(DebugRenderer3D renderer, {Vector3? cameraPosition}) {
    if (cameraPosition != null) {
      _lastCameraPosition = cameraPosition.clone();
    }
    final activeTarget = target;
    if (!enabled ||
        activeTarget == null ||
        !activeTarget.isEffectivelyVisible) {
      return;
    }

    final origin = _worldOriginOf(activeTarget);
    final (ax, ay, az) = _basisOf(activeTarget);
    final s = computeGizmoScale(cameraPosition);
    final thick = math.max(0.012, s * 0.025);

    Color colorFor(GizmoAxis3D handle, Color base) {
      if (_activeAxis == handle ||
          (_activeAxis == GizmoAxis3D.none && _hoveredAxis == handle)) {
        return _colorActive;
      }
      return base;
    }

    switch (mode) {
      case GizmoMode3D.translate:
        _drawTranslateAxis(
          renderer,
          origin,
          ax,
          s,
          colorFor(GizmoAxis3D.x, _colorX),
          thick,
        );
        _drawTranslateAxis(
          renderer,
          origin,
          ay,
          s,
          colorFor(GizmoAxis3D.y, _colorY),
          thick,
        );
        _drawTranslateAxis(
          renderer,
          origin,
          az,
          s,
          colorFor(GizmoAxis3D.z, _colorZ),
          thick,
        );
        _drawPlaneQuad(
          renderer,
          origin,
          ax,
          ay,
          s,
          colorFor(GizmoAxis3D.xy, _colorXY),
          thick * 0.8,
        );
        _drawPlaneQuad(
          renderer,
          origin,
          ax,
          az,
          s,
          colorFor(GizmoAxis3D.xz, _colorXZ),
          thick * 0.8,
        );
        _drawPlaneQuad(
          renderer,
          origin,
          ay,
          az,
          s,
          colorFor(GizmoAxis3D.yz, _colorYZ),
          thick * 0.8,
        );

      case GizmoMode3D.rotate:
        _drawRing(
          renderer,
          origin,
          ax,
          ay,
          az,
          s,
          colorFor(GizmoAxis3D.x, _colorX),
          thick,
        );
        _drawRing(
          renderer,
          origin,
          ay,
          az,
          ax,
          s,
          colorFor(GizmoAxis3D.y, _colorY),
          thick,
        );
        _drawRing(
          renderer,
          origin,
          az,
          ax,
          ay,
          s,
          colorFor(GizmoAxis3D.z, _colorZ),
          thick,
        );

      case GizmoMode3D.scale:
        _drawScaleAxis(
          renderer,
          origin,
          ax,
          s,
          colorFor(GizmoAxis3D.x, _colorX),
          thick,
        );
        _drawScaleAxis(
          renderer,
          origin,
          ay,
          s,
          colorFor(GizmoAxis3D.y, _colorY),
          thick,
        );
        _drawScaleAxis(
          renderer,
          origin,
          az,
          s,
          colorFor(GizmoAxis3D.z, _colorZ),
          thick,
        );
        final centerTransform = _basisTransform(origin, ax, ay, az);
        renderer.drawObb(
          Vector3.all(s * 0.1),
          centerTransform,
          color: colorFor(GizmoAxis3D.xyz, _colorCenter),
          thickness: thick,
        );
    }
  }

  /// Analytically picks the closest [GizmoAxis3D] handle intersected by [ray],
  /// or [GizmoAxis3D.none] when missed.
  GizmoAxis3D pickHandle(Ray ray, {Vector3? cameraPosition}) {
    final activeTarget = target;
    if (!enabled ||
        activeTarget == null ||
        !activeTarget.isEffectivelyVisible) {
      return GizmoAxis3D.none;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return GizmoAxis3D.none;
    }
    final ro = ray.origin;
    final rd = ray.direction / dirLen;

    final origin = _worldOriginOf(activeTarget);
    final (ax, ay, az) = _basisOf(activeTarget);
    final s = computeGizmoScale(cameraPosition);
    final tol = s * 0.12;

    switch (mode) {
      case GizmoMode3D.translate:
        final planeHit = _pickPlaneQuads(ro, rd, origin, ax, ay, az, s);
        if (planeHit != GizmoAxis3D.none) {
          return planeHit;
        }
        return _pickAxisSegments(
          ro,
          rd,
          origin,
          ax,
          ay,
          az,
          startFrac: 0.06,
          endFrac: 1.18,
          scale: s,
          tolerance: tol,
        );

      case GizmoMode3D.rotate:
        return _pickRotationRings(ro, rd, origin, ax, ay, az, s, tol);

      case GizmoMode3D.scale:
        if (_raySphereHit(ro, rd, origin, s * 0.16)) {
          return GizmoAxis3D.xyz;
        }
        final planeHit = _pickPlaneQuads(ro, rd, origin, ax, ay, az, s);
        if (planeHit != GizmoAxis3D.none) {
          return planeHit;
        }
        return _pickAxisSegments(
          ro,
          rd,
          origin,
          ax,
          ay,
          az,
          startFrac: 0.16,
          endFrac: 1.14,
          scale: s,
          tolerance: tol,
        );
    }
  }

  /// Starts an interactive gizmo drag along [axis] (or the handle picked by
  /// [ray] when [axis] is omitted), returning `true` if a handle captured the
  /// drag.
  bool beginDrag(
    Ray ray, {
    GizmoAxis3D? axis,
    Vector3? cameraPosition,
  }) {
    final activeTarget = target;
    if (!enabled ||
        activeTarget == null ||
        !activeTarget.isEffectivelyVisible) {
      return false;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return false;
    }
    final ro = ray.origin;
    final rd = ray.direction / dirLen;

    final chosen = axis ?? pickHandle(ray, cameraPosition: cameraPosition);
    if (chosen == GizmoAxis3D.none) {
      return false;
    }

    _activeAxis = chosen;
    _hoveredAxis = chosen;
    _isDragging = true;
    _dragStartSnapshot = TransformSnapshot3D.fromComponent(activeTarget);
    _dragStartWorldOrigin.setFrom(_worldOriginOf(activeTarget));
    final (ax, ay, az) = _basisOf(activeTarget);
    _dragAxisX.setFrom(ax);
    _dragAxisY.setFrom(ay);
    _dragAxisZ.setFrom(az);
    _dragGizmoScale = math.max(1e-4, computeGizmoScale(cameraPosition));

    if (activeTarget.parent case final Component3D parent3d) {
      final parentWorld = parent3d.worldTransformMatrix;
      _dragParentInverse.copyInverse(parentWorld);
      _dragParentWorldRot
        ..setFromRotation(parentWorld.getRotation())
        ..normalize();
      _dragParentWorldRotInv
        ..setFrom(_dragParentWorldRot)
        ..inverse();
    } else {
      _dragParentInverse.setIdentity();
      _dragParentWorldRot.setValues(0, 0, 0, 1);
      _dragParentWorldRotInv.setValues(0, 0, 0, 1);
    }

    switch (mode) {
      case GizmoMode3D.translate:
        if (_singleAxisVector(chosen) case final unitAxis?) {
          _dragStartAxisParam =
              _closestAxisParam(_dragStartWorldOrigin, unitAxis, ro, rd) ?? 0.0;
        } else {
          final normal = _planeNormalFor(chosen, rd);
          _dragPlaneNormal.setFrom(normal);
          final hit =
              _intersectPlane(ro, rd, _dragStartWorldOrigin, normal) ??
              _dragStartWorldOrigin;
          _dragStartPlanePoint.setFrom(hit);
        }

      case GizmoMode3D.rotate:
        final ringAxis = _singleAxisVector(chosen) ?? _dragAxisY;
        _dragRingAxis.setFrom(ringAxis);
        final denom = ringAxis.dot(rd);
        if (denom.abs() > 0.06) {
          _dragRingEdgeOn = false;
          final hit =
              _intersectPlane(ro, rd, _dragStartWorldOrigin, ringAxis) ??
              (_dragStartWorldOrigin + _perpendicularUnit(ringAxis));
          final radial = hit - _dragStartWorldOrigin;
          radial.sub(ringAxis * ringAxis.dot(radial));
          if (radial.length2 > 1e-10) {
            radial.normalize();
          } else {
            radial.setFrom(_perpendicularUnit(ringAxis));
          }
          _dragStartRingRadial.setFrom(radial);
        } else {
          _dragRingEdgeOn = true;
          _dragPlaneNormal.setFrom(-rd);
          final hit =
              _intersectPlane(
                ro,
                rd,
                _dragStartWorldOrigin,
                _dragPlaneNormal,
              ) ??
              _dragStartWorldOrigin;
          _dragStartPlanePoint.setFrom(hit);
          final tangent = ringAxis.cross(rd);
          if (tangent.length2 > 1e-10) {
            tangent.normalize();
          } else {
            tangent.setFrom(_perpendicularUnit(ringAxis));
          }
          _dragUniformDir.setFrom(tangent);
        }

      case GizmoMode3D.scale:
        if (_singleAxisVector(chosen) case final unitAxis?) {
          _dragStartAxisParam =
              _closestAxisParam(_dragStartWorldOrigin, unitAxis, ro, rd) ?? 0.0;
        } else {
          final normal = chosen == GizmoAxis3D.xyz
              ? -rd
              : _planeNormalFor(chosen, rd);
          _dragPlaneNormal.setFrom(normal);
          final hit =
              _intersectPlane(ro, rd, _dragStartWorldOrigin, normal) ??
              _dragStartWorldOrigin;
          _dragStartPlanePoint.setFrom(hit);
          if (chosen == GizmoAxis3D.xyz) {
            final upRef = rd.y.abs() < 0.9
                ? Vector3(0, 1, 0)
                : Vector3(1, 0, 0);
            final right = rd.cross(upRef)..normalize();
            final up = right.cross(rd)..normalize();
            _dragUniformDir
              ..setFrom(right + up)
              ..normalize();
          } else {
            final (u, v) = _planeAxesFor(chosen);
            _dragUniformDir
              ..setFrom(u + v)
              ..normalize();
          }
        }
    }
    return true;
  }

  /// Solves and applies the constrained transform update for [ray] during an
  /// active drag.
  bool updateDrag(Ray ray) {
    final activeTarget = target;
    final start = _dragStartSnapshot;
    if (!_isDragging || activeTarget == null || start == null) {
      return false;
    }
    final dirLen = ray.direction.length;
    if (dirLen <= 1e-12) {
      return false;
    }
    final ro = ray.origin;
    final rd = ray.direction / dirLen;

    switch (mode) {
      case GizmoMode3D.translate:
        _solveTranslate(activeTarget, ro, rd);
      case GizmoMode3D.rotate:
        _solveRotate(activeTarget, start, ro, rd);
      case GizmoMode3D.scale:
        _solveScale(activeTarget, start, ro, rd);
    }
    return true;
  }

  /// Finishes the active drag and pushes a reversible [GizmoTransformCommand3D]
  /// onto [history] when the transform changed.
  bool endDrag() {
    if (!_isDragging) {
      return false;
    }
    final activeTarget = target;
    final start = _dragStartSnapshot;
    _isDragging = false;
    _activeAxis = GizmoAxis3D.none;
    _dragStartSnapshot = null;
    if (activeTarget != null && start != null) {
      final after = TransformSnapshot3D.fromComponent(activeTarget);
      history.record(activeTarget, before: start, after: after);
    }
    return true;
  }

  /// Cancels the active drag and restores the target's initial TRS state
  /// without recording an undo entry.
  void cancelDrag() {
    if (!_isDragging) {
      return;
    }
    final activeTarget = target;
    final start = _dragStartSnapshot;
    _isDragging = false;
    _activeAxis = GizmoAxis3D.none;
    _dragStartSnapshot = null;
    if (activeTarget != null && start != null) {
      start.applyTo(activeTarget);
    }
  }

  void _solveTranslate(Component3D activeTarget, Vector3 ro, Vector3 rd) {
    final worldOffset = Vector3.zero();
    final snap = translateSnap;

    if (_singleAxisVector(_activeAxis) case final unitAxis?) {
      final param = _closestAxisParam(_dragStartWorldOrigin, unitAxis, ro, rd);
      if (param == null) {
        return;
      }
      var delta = param - _dragStartAxisParam;
      if (snap != null && snap > 0) {
        delta = (delta / snap).round() * snap;
      }
      worldOffset.setFrom(unitAxis * delta);
    } else if (_activeAxis == GizmoAxis3D.xyz) {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      worldOffset.setFrom(hit - _dragStartPlanePoint);
      if (snap != null && snap > 0) {
        worldOffset.setValues(
          (worldOffset.x / snap).round() * snap,
          (worldOffset.y / snap).round() * snap,
          (worldOffset.z / snap).round() * snap,
        );
      }
    } else {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      final rawDiff = hit - _dragStartPlanePoint;
      final (axisU, axisV) = _planeAxesFor(_activeAxis);
      var du = rawDiff.dot(axisU);
      var dv = rawDiff.dot(axisV);
      if (snap != null && snap > 0) {
        du = (du / snap).round() * snap;
        dv = (dv / snap).round() * snap;
      }
      worldOffset
        ..setFrom(axisU * du)
        ..add(axisV * dv);
    }

    final newWorldPos = _dragStartWorldOrigin + worldOffset;
    final newLocalPos = _dragParentInverse.transformed3(newWorldPos);
    activeTarget.position.setFrom(newLocalPos);
  }

  void _solveRotate(
    Component3D activeTarget,
    TransformSnapshot3D start,
    Vector3 ro,
    Vector3 rd,
  ) {
    double angle;
    if (!_dragRingEdgeOn) {
      final hit = _intersectPlane(ro, rd, _dragStartWorldOrigin, _dragRingAxis);
      if (hit == null) {
        return;
      }
      final radial = hit - _dragStartWorldOrigin;
      radial.sub(_dragRingAxis * _dragRingAxis.dot(radial));
      if (radial.length2 <= 1e-10) {
        return;
      }
      radial.normalize();
      final cross = _dragStartRingRadial.cross(radial);
      final sinAngle = _dragRingAxis.dot(cross);
      final cosAngle = _dragStartRingRadial.dot(radial).clamp(-1.0, 1.0);
      angle = math.atan2(sinAngle, cosAngle);
    } else {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      final delta = (hit - _dragStartPlanePoint).dot(_dragUniformDir);
      angle = delta / _dragGizmoScale;
    }

    final snap = rotateSnapRadians;
    if (snap != null && snap > 0) {
      angle = (angle / snap).round() * snap;
    }

    final worldDelta = Quaternion.axisAngle(_dragRingAxis, angle);
    final startWorldRot = _dragParentWorldRot * start.rotation;
    final nextWorldRot = worldDelta * startWorldRot;
    final nextLocalRot = (_dragParentWorldRotInv * nextWorldRot)..normalize();
    activeTarget.rotation.setFrom(nextLocalRot);
  }

  void _solveScale(
    Component3D activeTarget,
    TransformSnapshot3D start,
    Vector3 ro,
    Vector3 rd,
  ) {
    double delta;
    if (_singleAxisVector(_activeAxis) case final unitAxis?) {
      final param = _closestAxisParam(_dragStartWorldOrigin, unitAxis, ro, rd);
      if (param == null) {
        return;
      }
      delta = param - _dragStartAxisParam;
    } else {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      delta = (hit - _dragStartPlanePoint).dot(_dragUniformDir);
    }

    final factor = math.max(0.01, 1.0 + delta / _dragGizmoScale);
    final next = start.scale.clone();
    switch (_activeAxis) {
      case GizmoAxis3D.x:
        next.x = _snapScaleValue(start.scale.x * factor);
      case GizmoAxis3D.y:
        next.y = _snapScaleValue(start.scale.y * factor);
      case GizmoAxis3D.z:
        next.z = _snapScaleValue(start.scale.z * factor);
      case GizmoAxis3D.xy:
        next.x = _snapScaleValue(start.scale.x * factor);
        next.y = _snapScaleValue(start.scale.y * factor);
      case GizmoAxis3D.xz:
        next.x = _snapScaleValue(start.scale.x * factor);
        next.z = _snapScaleValue(start.scale.z * factor);
      case GizmoAxis3D.yz:
        next.y = _snapScaleValue(start.scale.y * factor);
        next.z = _snapScaleValue(start.scale.z * factor);
      case GizmoAxis3D.xyz:
        next.setValues(
          _snapScaleValue(start.scale.x * factor),
          _snapScaleValue(start.scale.y * factor),
          _snapScaleValue(start.scale.z * factor),
        );
      case GizmoAxis3D.none:
        return;
    }
    activeTarget.scale.setFrom(next);
  }

  double _snapScaleValue(double raw) {
    final snap = scaleSnap;
    if (snap == null || snap <= 0) {
      return raw;
    }
    final snapped = (raw / snap).round() * snap;
    return raw >= 0 && snapped <= 0 ? snap : snapped;
  }

  Vector3? _singleAxisVector(GizmoAxis3D axis) {
    return switch (axis) {
      GizmoAxis3D.x => _dragAxisX,
      GizmoAxis3D.y => _dragAxisY,
      GizmoAxis3D.z => _dragAxisZ,
      _ => null,
    };
  }

  Vector3 _planeNormalFor(GizmoAxis3D axis, Vector3 rd) {
    return switch (axis) {
      GizmoAxis3D.xy => _dragAxisZ,
      GizmoAxis3D.xz => _dragAxisY,
      GizmoAxis3D.yz => _dragAxisX,
      _ => -rd,
    };
  }

  (Vector3, Vector3) _planeAxesFor(GizmoAxis3D axis) {
    return switch (axis) {
      GizmoAxis3D.xy => (_dragAxisX, _dragAxisY),
      GizmoAxis3D.xz => (_dragAxisX, _dragAxisZ),
      GizmoAxis3D.yz => (_dragAxisY, _dragAxisZ),
      _ => (_dragAxisX, _dragAxisY),
    };
  }

  (Vector3, Vector3, Vector3) _basisOf(Component3D comp) {
    if (space == GizmoSpace3D.world && mode != GizmoMode3D.scale) {
      return (Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1));
    }
    final m = comp.worldTransformMatrix.storage;
    final ax = Vector3(m[0], m[1], m[2]);
    final ay = Vector3(m[4], m[5], m[6]);
    final az = Vector3(m[8], m[9], m[10]);
    if (ax.length2 > 1e-12) {
      ax.normalize();
    } else {
      ax.setValues(1, 0, 0);
    }
    if (ay.length2 > 1e-12) {
      ay.normalize();
    } else {
      ay.setValues(0, 1, 0);
    }
    if (az.length2 > 1e-12) {
      az.normalize();
    } else {
      az.setValues(0, 0, 1);
    }
    return (ax, ay, az);
  }

  static Vector3 _worldOriginOf(Component3D comp) {
    final m = comp.worldTransformMatrix.storage;
    return Vector3(m[12], m[13], m[14]);
  }

  static Matrix4 _basisTransform(
    Vector3 origin,
    Vector3 ax,
    Vector3 ay,
    Vector3 az,
  ) {
    return Matrix4.columns(
      Vector4(ax.x, ax.y, ax.z, 0),
      Vector4(ay.x, ay.y, ay.z, 0),
      Vector4(az.x, az.y, az.z, 0),
      Vector4(origin.x, origin.y, origin.z, 1),
    );
  }

  static void _drawTranslateAxis(
    DebugRenderer3D renderer,
    Vector3 origin,
    Vector3 axis,
    double scale,
    Color color,
    double thickness,
  ) {
    final shaftEnd = origin + axis * scale;
    final tip = origin + axis * (scale * 1.18);
    renderer
      ..drawLine(origin, shaftEnd, color: color, thickness: thickness)
      ..drawCone(
        tip,
        -axis,
        length: scale * 0.18,
        halfAngleRad: 0.34,
        color: color,
        segments: 8,
        thickness: thickness * 0.75,
      );
  }

  static void _drawPlaneQuad(
    DebugRenderer3D renderer,
    Vector3 origin,
    Vector3 u,
    Vector3 v,
    double scale,
    Color color,
    double thickness,
  ) {
    final lo = scale * 0.22;
    final hi = scale * 0.42;
    final p0 = origin + u * lo + v * lo;
    final p1 = origin + u * hi + v * lo;
    final p2 = origin + u * hi + v * hi;
    final p3 = origin + u * lo + v * hi;
    renderer.drawPolyline(
      [p0, p1, p2, p3],
      closed: true,
      color: color,
      thickness: thickness,
    );
  }

  static void _drawRing(
    DebugRenderer3D renderer,
    Vector3 origin,
    Vector3 normal,
    Vector3 tangentA,
    Vector3 tangentB,
    double radius,
    Color color,
    double thickness,
  ) {
    const segments = 32;
    final pts = <Vector3>[];
    for (var i = 0; i < segments; i++) {
      final t = (i / segments) * 2.0 * math.pi;
      pts.add(
        origin +
            tangentA * (math.cos(t) * radius) +
            tangentB * (math.sin(t) * radius),
      );
    }
    renderer.drawPolyline(
      pts,
      closed: true,
      color: color,
      thickness: thickness,
    );
  }

  static void _drawScaleAxis(
    DebugRenderer3D renderer,
    Vector3 origin,
    Vector3 axis,
    double scale,
    Color color,
    double thickness,
  ) {
    final end = origin + axis * scale;
    renderer.drawLine(origin, end, color: color, thickness: thickness);
    final perpA = _perpendicularUnit(axis);
    final perpB = axis.cross(perpA)..normalize();
    renderer.drawObb(
      Vector3.all(scale * 0.075),
      _basisTransform(end, axis, perpA, perpB),
      color: color,
      thickness: thickness * 0.85,
    );
  }

  static GizmoAxis3D _pickPlaneQuads(
    Vector3 ro,
    Vector3 rd,
    Vector3 origin,
    Vector3 ax,
    Vector3 ay,
    Vector3 az,
    double scale,
  ) {
    final lo = scale * 0.2;
    final hi = scale * 0.44;
    var bestT = double.infinity;
    var bestAxis = GizmoAxis3D.none;

    void checkPlane(GizmoAxis3D candidate, Vector3 n, Vector3 u, Vector3 v) {
      final denom = n.dot(rd);
      if (denom.abs() <= 1e-6) {
        return;
      }
      final t = n.dot(origin - ro) / denom;
      if (t <= 0 || t >= bestT) {
        return;
      }
      final rel = (ro + rd * t) - origin;
      final cu = rel.dot(u);
      final cv = rel.dot(v);
      if (cu >= lo && cu <= hi && cv >= lo && cv <= hi) {
        bestT = t;
        bestAxis = candidate;
      }
    }

    checkPlane(GizmoAxis3D.xy, az, ax, ay);
    checkPlane(GizmoAxis3D.xz, ay, ax, az);
    checkPlane(GizmoAxis3D.yz, ax, ay, az);
    return bestAxis;
  }

  static GizmoAxis3D _pickAxisSegments(
    Vector3 ro,
    Vector3 rd,
    Vector3 origin,
    Vector3 ax,
    Vector3 ay,
    Vector3 az, {
    required double startFrac,
    required double endFrac,
    required double scale,
    required double tolerance,
  }) {
    var bestDist = tolerance;
    var bestAxis = GizmoAxis3D.none;

    void checkAxis(GizmoAxis3D candidate, Vector3 dir) {
      final a = origin + dir * (scale * startFrac);
      final len = scale * (endFrac - startFrac);
      final dist = _raySegmentDistance(ro, rd, a, dir, len);
      if (dist < bestDist) {
        bestDist = dist;
        bestAxis = candidate;
      }
    }

    checkAxis(GizmoAxis3D.x, ax);
    checkAxis(GizmoAxis3D.y, ay);
    checkAxis(GizmoAxis3D.z, az);
    return bestAxis;
  }

  static GizmoAxis3D _pickRotationRings(
    Vector3 ro,
    Vector3 rd,
    Vector3 origin,
    Vector3 ax,
    Vector3 ay,
    Vector3 az,
    double radius,
    double tolerance,
  ) {
    var bestDist = tolerance;
    var bestAxis = GizmoAxis3D.none;

    void checkRing(
      GizmoAxis3D candidate,
      Vector3 normal,
      Vector3 tangentA,
      Vector3 tangentB,
    ) {
      final denom = normal.dot(rd);
      if (denom.abs() > 0.08) {
        final t = normal.dot(origin - ro) / denom;
        if (t > 0) {
          final rel = (ro + rd * t) - origin;
          final radialDist = (rel.length - radius).abs();
          if (radialDist < bestDist) {
            bestDist = radialDist;
            bestAxis = candidate;
            return;
          }
        }
      }
      // Edge-on polyline fallback (slightly biased behind face-on intersections
      // where two orthogonal rings cross).
      final edgeBias = radius * 0.025;
      const segs = 24;
      for (var i = 0; i < segs; i++) {
        final t0 = (i / segs) * 2.0 * math.pi;
        final t1 = ((i + 1) / segs) * 2.0 * math.pi;
        final p0 =
            origin +
            tangentA * (math.cos(t0) * radius) +
            tangentB * (math.sin(t0) * radius);
        final p1 =
            origin +
            tangentA * (math.cos(t1) * radius) +
            tangentB * (math.sin(t1) * radius);
        final diff = p1 - p0;
        final len = diff.length;
        if (len > 1e-6) {
          final d = _raySegmentDistance(ro, rd, p0, diff / len, len) + edgeBias;
          if (d < bestDist) {
            bestDist = d;
            bestAxis = candidate;
          }
        }
      }
    }

    checkRing(GizmoAxis3D.x, ax, ay, az);
    checkRing(GizmoAxis3D.y, ay, az, ax);
    checkRing(GizmoAxis3D.z, az, ax, ay);
    return bestAxis;
  }

  static double _raySegmentDistance(
    Vector3 ro,
    Vector3 rd,
    Vector3 segStart,
    Vector3 segDir,
    double segLen,
  ) {
    final w0 = ro - segStart;
    final b = rd.dot(segDir);
    final d = rd.dot(w0);
    final e = segDir.dot(w0);
    final denom = 1.0 - b * b;

    var s = denom > 1e-8 ? (e - b * d) / denom : e;
    s = s.clamp(0.0, segLen);
    var t = math.max(0.0, rd.dot((segStart + segDir * s) - ro));
    s = segDir.dot((ro + rd * t) - segStart).clamp(0.0, segLen);
    t = math.max(0.0, rd.dot((segStart + segDir * s) - ro));

    final pRay = ro + rd * t;
    final pSeg = segStart + segDir * s;
    return pRay.distanceTo(pSeg);
  }

  static bool _raySphereHit(
    Vector3 ro,
    Vector3 rd,
    Vector3 center,
    double radius,
  ) {
    final oc = ro - center;
    final b = oc.dot(rd);
    final c = oc.dot(oc) - radius * radius;
    final disc = b * b - c;
    if (disc < 0) {
      return false;
    }
    return -b + math.sqrt(disc) >= 0;
  }

  static double? _closestAxisParam(
    Vector3 anchor,
    Vector3 unitAxis,
    Vector3 ro,
    Vector3 rd,
  ) {
    final w = anchor - ro;
    final b = unitAxis.dot(rd);
    final denom = 1.0 - b * b;
    if (denom <= 1e-6) {
      return null;
    }
    final d = unitAxis.dot(w);
    final e = rd.dot(w);
    return (b * e - d) / denom;
  }

  static Vector3? _intersectPlane(
    Vector3 ro,
    Vector3 rd,
    Vector3 planeOrigin,
    Vector3 planeNormal,
  ) {
    final denom = planeNormal.dot(rd);
    if (denom.abs() <= 1e-7) {
      return null;
    }
    final t = planeNormal.dot(planeOrigin - ro) / denom;
    if (t < 0) {
      return null;
    }
    return ro + rd * t;
  }

  static Vector3 _perpendicularUnit(Vector3 n) {
    final ref = n.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
    return ref.cross(n)..normalize();
  }
}
