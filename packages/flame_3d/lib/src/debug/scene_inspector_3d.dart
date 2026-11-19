import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/camera.dart' show Ray, World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/debug/debug_renderer_3d.dart';
import 'package:flame_3d/src/debug/transform_gizmo_3d.dart';

/// Diagnostic summary for a single [Component3D] node discovered by
/// [SceneInspector3D.summarize].
class SceneNodeInfo3D({
  required final Component3D component,
  required final int depth,
  required final String typeName,
  required final bool visible,
  required final bool effectivelyVisible,
  required final Set<String> tags,
  required final int estimatedInstances,
  required final int estimatedTriangles,
  required Vector3 worldPosition,
}) {
  /// World-space translation of [component] at inspection time.
  final Vector3 worldPosition = worldPosition.clone();
}

/// Aggregated hierarchy, visibility, instance, and triangle telemetry of a
/// [World3D] returned by [SceneInspector3D.summarize].
class const SceneHierarchySummary3D({
  required final int totalNodes,
  required final int visibleNodes,
  required final int hiddenNodes,
  required final int meshNodeCount,
  required final int lightNodeCount,
  required final int groupNodeCount,
  required final int maxDepth,
  required final int estimatedInstances,
  required final int estimatedTriangles,
  required final List<SceneNodeInfo3D> nodes,
});

/// Runtime 3D scene inspector tracking active [Component3D] selection, drawing
/// world AABB + local basis highlights into [DebugRenderer3D], enumerating
/// scene hierarchy telemetry, and binding [TransformGizmo3D] to the selection.
class SceneInspector3D({
  TransformGizmo3D? gizmo,
  var bool enabled = true,
  var bool drawSelectionBounds = true,
  var bool drawSelectionBasis = true,
  var Color selectionBoundsColor = const Color(0xFFF59E0B),
  var double basisAxisSize = 0.65,
  final void Function(Component3D? selected)? onSelectionChanged,
}) {
  /// Transform gizmo automatically synchronized to [selected].
  final TransformGizmo3D gizmo = gizmo ?? TransformGizmo3D();

  Component3D? _selected;

  /// Currently selected [Component3D], or `null` when nothing is selected.
  Component3D? get selected => _selected;

  /// Selects [component] (or clears selection when `null`) and binds [gizmo]
  /// to it.
  void select(Component3D? component) {
    if (identical(_selected, component)) {
      gizmo.target = component;
      return;
    }
    if (gizmo.isDragging) {
      gizmo.cancelDrag();
    }
    _selected = component;
    gizmo.target = component;
    onSelectionChanged?.call(component);
  }

  /// Clears the active selection.
  void clearSelection() => select(null);

  /// Ray-picks a visible [Object3D] in [world] (unless [ray] hits an active
  /// [gizmo] handle first), updates [selected], and returns it.
  Component3D? pickInWorld(
    World3D world,
    Ray ray, {
    Vector3? cameraPosition,
    bool Function(Object3D object)? filter,
  }) {
    if (!enabled) {
      return _selected;
    }
    if (_selected != null &&
        gizmo.pickHandle(ray, cameraPosition: cameraPosition) !=
            GizmoAxis3D.none) {
      return _selected;
    }
    final hit = world.raycast(
      ray,
      filter: (obj) =>
          obj.isEffectivelyVisible &&
          obj is! DebugRenderer3D &&
          (filter == null || filter(obj)),
    );
    select(hit?.object);
    return _selected;
  }

  /// Emits world AABB highlight, local basis triad, and [gizmo] handles for
  /// [selected] into [renderer].
  void render(DebugRenderer3D renderer, {Vector3? cameraPosition}) {
    if (!enabled) {
      return;
    }
    final current = _selected;
    if (current == null) {
      return;
    }
    gizmo.target = current;
    if (drawSelectionBounds) {
      renderer.drawAabb(
        current.aabb,
        color: selectionBoundsColor,
        thickness: renderer.lineThickness * 1.25,
      );
    }
    if (drawSelectionBasis) {
      renderer.drawAxes(
        current.worldTransformMatrix,
        size: basisAxisSize,
        thickness: renderer.lineThickness * 1.15,
      );
    }
    gizmo.render(renderer, cameraPosition: cameraPosition);
  }

  /// Walks [world]'s component hierarchy in pre-order and computes node,
  /// visibility, instance, and triangle estimates.
  SceneHierarchySummary3D summarize(World3D world) {
    final nodes = <SceneNodeInfo3D>[];
    var visibleCount = 0;
    var hiddenCount = 0;
    var meshNodes = 0;
    var lightNodes = 0;
    var groupNodes = 0;
    var maxDepth = 0;
    var totalInstances = 0;
    var totalTriangles = 0;

    void visit(Component comp, int depth) {
      if (comp is DebugRenderer3D) {
        return;
      }
      if (comp is Component3D) {
        if (depth > maxDepth) {
          maxDepth = depth;
        }
        final effVisible = comp.isEffectivelyVisible;
        if (effVisible) {
          visibleCount++;
        } else {
          hiddenCount++;
        }

        final (typeName, instEst, triEst) = _classifyAndEstimate(comp);
        if (comp is LightComponent) {
          lightNodes++;
        } else if (comp is Object3D) {
          meshNodes++;
        } else {
          groupNodes++;
        }
        if (effVisible) {
          totalInstances += instEst;
          totalTriangles += triEst;
        }

        final wm = comp.worldTransformMatrix.storage;
        nodes.add(
          SceneNodeInfo3D(
            component: comp,
            depth: depth,
            typeName: typeName,
            visible: comp.visible,
            effectivelyVisible: effVisible,
            tags: comp.tags3D,
            estimatedInstances: effVisible ? instEst : 0,
            estimatedTriangles: effVisible ? triEst : 0,
            worldPosition: Vector3(wm[12], wm[13], wm[14]),
          ),
        );
      }

      final nextDepth = comp is Component3D ? depth + 1 : depth;
      for (final child in comp.children) {
        visit(child, nextDepth);
      }
    }

    for (final child in world.children) {
      visit(child, 0);
    }

    return SceneHierarchySummary3D(
      totalNodes: nodes.length,
      visibleNodes: visibleCount,
      hiddenNodes: hiddenCount,
      meshNodeCount: meshNodes,
      lightNodeCount: lightNodes,
      groupNodeCount: groupNodes,
      maxDepth: maxDepth,
      estimatedInstances: totalInstances,
      estimatedTriangles: totalTriangles,
      nodes: List.unmodifiable(nodes),
    );
  }

  static (String, int, int) _classifyAndEstimate(Component3D comp) {
    switch (comp) {
      case final MeshComponent m:
        return ('MeshComponent', 1, _meshTriangles(m.mesh));
      case final LodMeshComponent lod:
        final lvl = math.min(lod.lastSelectedLevel, lod.levels.length - 1);
        return (
          'LodMeshComponent',
          1,
          _meshTriangles(lod.levels[math.max(0, lvl)].mesh),
        );
      case final InstancedGroup3D group:
        final trisPer = _meshTriangles(group.mesh);
        return (
          'InstancedGroup3D',
          group.length,
          trisPer * group.length,
        );
      case final LightComponent _:
        return ('LightComponent', 0, 0);
      case final SkyboxComponent3D _:
        return ('SkyboxComponent3D', 1, 2);
      case final Text3DComponent _:
        return ('Text3DComponent', 1, 2);
      case final Object3D _:
        return ('Object3D', 1, 0);
      case final Group3D _:
        return ('Group3D', 0, 0);
      case _:
        return ('Component3D', 0, 0);
    }
  }

  static int _meshTriangles(Mesh mesh) {
    var tris = 0;
    for (final surface in mesh.surfaces) {
      tris += surface.indexCount ~/ 3;
    }
    return tris;
  }
}
