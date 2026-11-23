import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/debug/debug_renderer_3d.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

part 'transform_gizmo_geometry_3d.dart';
part 'transform_gizmo_solver_3d.dart';

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
        final centerTransform = _gizmoBasisTransform(origin, ax, ay, az);
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

    _initDragForMode(chosen, ro, rd);
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
}
