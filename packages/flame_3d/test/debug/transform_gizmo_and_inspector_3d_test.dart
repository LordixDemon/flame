import 'dart:math' as math;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/debug.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransformGizmo3D scaling & handle picking', () {
    test('computeGizmoScale maintains constant screen-space proportion', () {
      final node = Group3D(position: Vector3.zero());
      final gizmo = TransformGizmo3D(
        target: node,
        screenScaleFactor: 0.2,
        minWorldSize: 0.25,
        maxWorldSize: 20,
      );

      // Without camera position, falls back to baseSize (1.0).
      expect(gizmo.computeGizmoScale(), closeTo(1.0, 1e-6));

      final nearScale = gizmo.computeGizmoScale(Vector3(0, 0, 5));
      final farScale = gizmo.computeGizmoScale(Vector3(0, 0, 25));
      expect(nearScale, closeTo(1.0, 1e-6));
      expect(farScale, closeTo(5.0, 1e-6));

      // Clamping to [minWorldSize, maxWorldSize].
      expect(gizmo.computeGizmoScale(Vector3(0, 0, 0.2)), closeTo(0.25, 1e-6));
      expect(gizmo.computeGizmoScale(Vector3(0, 0, 500)), closeTo(20.0, 1e-6));
    });

    test('pickHandle selects axes, planes, rings, and uniform center cube', () {
      final node = Group3D();
      final gizmo = TransformGizmo3D(target: node);

      // Translate mode: +X, +Y, +Z shafts and XY plane quad.
      expect(
        gizmo.pickHandle(_ray(Vector3(0.75, 0, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.x,
      );
      expect(
        gizmo.pickHandle(_ray(Vector3(0, 0.75, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.y,
      );
      expect(
        gizmo.pickHandle(_ray(Vector3(4, 0, 0.75), Vector3(-1, 0, 0))),
        GizmoAxis3D.z,
      );
      expect(
        gizmo.pickHandle(_ray(Vector3(0.3, 0.3, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.xy,
      );
      expect(
        gizmo.pickHandle(_ray(Vector3(5, 5, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.none,
      );

      // Rotate mode: Z-ring (radius 1 in XY plane) and Y-ring (XZ plane).
      gizmo.mode = GizmoMode3D.rotate;
      expect(
        gizmo.pickHandle(_ray(Vector3(1, 0, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.z,
      );
      expect(
        gizmo.pickHandle(_ray(Vector3(1, 4, 0), Vector3(0, -1, 0))),
        GizmoAxis3D.y,
      );

      // Scale mode: center XYZ cube and +X end cube.
      gizmo.mode = GizmoMode3D.scale;
      expect(
        gizmo.pickHandle(_ray(Vector3(0, 0, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.xyz,
      );
      expect(
        gizmo.pickHandle(_ray(Vector3(1, 0, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.x,
      );

      // Hidden target is never picked.
      node.visible = false;
      expect(
        gizmo.pickHandle(_ray(Vector3(0, 0, 4), Vector3(0, 0, -1))),
        GizmoAxis3D.none,
      );
    });
  });

  group('TransformGizmo3D ray-drag solver, snapping & undo/redo', () {
    test('translates along axis and plane with snap & parent transform', () {
      final child = Group3D(position: Vector3(1, 0, 0));
      final parent = Group3D(
        position: Vector3(10, 0, 0),
        children: [child],
      );
      World3D(children: [parent]);

      final gizmo = TransformGizmo3D(
        target: child,
        translateSnap: 0.5,
      );

      // Child starts at world (11, 0, 0). Grab its +X handle at world x = 11.7.
      final started = gizmo.beginDrag(
        _ray(Vector3(11.7, 0, 5), Vector3(0, 0, -1)),
      );
      expect(started, isTrue);
      expect(gizmo.activeAxis, GizmoAxis3D.x);

      // Drag +1.22 units along X -> snaps to +1.0 -> local x becomes 2.0!
      gizmo.updateDrag(_ray(Vector3(12.92, 0, 5), Vector3(0, 0, -1)));
      expect(child.position, closeToVector3(Vector3(2, 0, 0)));

      // Drag +1.4 units along X -> snaps to +1.5 -> local x becomes 2.5!
      gizmo.updateDrag(_ray(Vector3(13.1, 0, 5), Vector3(0, 0, -1)));
      expect(child.position, closeToVector3(Vector3(2.5, 0, 0)));
      gizmo.endDrag();

      // XZ plane drag on root node.
      final box = Group3D();
      gizmo
        ..target = box
        ..translateSnap = 0.25;
      expect(
        gizmo.beginDrag(
          _ray(Vector3(0.3, 5, 0.3), Vector3(0, -1, 0)),
        ),
        isTrue,
      );
      expect(gizmo.activeAxis, GizmoAxis3D.xz);

      gizmo.updateDrag(_ray(Vector3(1.04, 5, -0.46), Vector3(0, -1, 0)));
      expect(box.position, closeToVector3(Vector3(0.75, 0, -0.75)));
      gizmo.endDrag();
    });

    test('rotates around world/local rings with angle snapping', () {
      final node = Group3D();
      const snap15Deg = math.pi / 12;
      final gizmo = TransformGizmo3D(
        target: node,
        mode: GizmoMode3D.rotate,
        rotateSnapRadians: snap15Deg,
      );

      // Grab Y-ring at (+1, 0, 0) from above.
      expect(
        gizmo.beginDrag(_ray(Vector3(1, 5, 0), Vector3(0, -1, 0))),
        isTrue,
      );
      expect(gizmo.activeAxis, GizmoAxis3D.y);

      // Sweep ~47 degrees toward -Z (right-hand +Y rotation carries +X -> -Z).
      const angle47 = 47 * math.pi / 180;
      gizmo.updateDrag(
        _ray(
          Vector3(math.cos(angle47), 5, -math.sin(angle47)),
          Vector3(0, -1, 0),
        ),
      );
      gizmo.endDrag();

      // Snapped to 45 degrees (3 * 15 deg = pi / 4) around +Y.
      final rotatedX = node.worldTransformMatrix.transformed3(Vector3(1, 0, 0));
      expect(
        rotatedX,
        closeToVector3(Vector3(math.sqrt1_2, 0, -math.sqrt1_2), 1e-5),
      );

      // Local-space rotation around node's rotated local X axis.
      gizmo
        ..space = GizmoSpace3D.local
        ..rotateSnapRadians = null;
      final startRot = node.rotation.clone();
      expect(
        gizmo.beginDrag(
          _ray(Vector3(0, 1, 5), Vector3(0, 0, -1)),
          axis: GizmoAxis3D.x,
        ),
        isTrue,
      );
      gizmo.updateDrag(_ray(Vector3(-0.7, 0.7, 5), Vector3(0, 0, -1)));
      expect(
        TransformSnapshot3D.fromComponent(node).closeTo(
          TransformSnapshot3D(
            position: Vector3.zero(),
            rotation: startRot,
            scale: Vector3.all(1),
          ),
        ),
        isFalse,
      );
      gizmo.cancelDrag();
      expect(
        TransformSnapshot3D.fromComponent(node).closeTo(
          TransformSnapshot3D(
            position: Vector3.zero(),
            rotation: startRot,
            scale: Vector3.all(1),
          ),
        ),
        isTrue,
      );
    });

    test('scales single-axis and uniform xyz with snapping & undo/redo', () {
      final node = Group3D();
      final gizmo = TransformGizmo3D(
        target: node,
        mode: GizmoMode3D.scale,
        scaleSnap: 0.25,
      );

      // 1. Single-axis X scale: drag +0.52 -> factor 1.52 -> snaps to 1.5.
      expect(
        gizmo.beginDrag(_ray(Vector3(1, 0, 5), Vector3(0, 0, -1))),
        isTrue,
      );
      expect(gizmo.activeAxis, GizmoAxis3D.x);
      gizmo.updateDrag(_ray(Vector3(1.52, 0, 5), Vector3(0, 0, -1)));
      expect(node.scale, closeToVector3(Vector3(1.5, 1, 1)));
      gizmo.endDrag();

      // 2. Uniform XYZ scale from center handle.
      expect(
        gizmo.beginDrag(_ray(Vector3(0, 0, 5), Vector3(0, 0, -1))),
        isTrue,
      );
      expect(gizmo.activeAxis, GizmoAxis3D.xyz);
      // Dragging diagonally (+right, +up) by sqrt(2)/2 projects to +1.0 -> 2x.
      const diag = math.sqrt1_2;
      gizmo.updateDrag(_ray(Vector3(diag, diag, 5), Vector3(0, 0, -1)));
      expect(node.scale, closeToVector3(Vector3(3, 2, 2)));
      gizmo.endDrag();

      expect(gizmo.history.undoCount, 2);
      expect(gizmo.history.canUndo, isTrue);
      expect(gizmo.history.canRedo, isFalse);

      // Undo uniform scale -> back to (1.5, 1, 1).
      expect(gizmo.history.undo(), isTrue);
      expect(node.scale, closeToVector3(Vector3(1.5, 1, 1)));
      expect(gizmo.history.canRedo, isTrue);

      // Undo X scale -> back to (1, 1, 1).
      expect(gizmo.history.undo(), isTrue);
      expect(node.scale, closeToVector3(Vector3(1, 1, 1)));
      expect(gizmo.history.canUndo, isFalse);

      // Redo both steps.
      expect(gizmo.history.redo(), isTrue);
      expect(node.scale, closeToVector3(Vector3(1.5, 1, 1)));
      expect(gizmo.history.redo(), isTrue);
      expect(node.scale, closeToVector3(Vector3(3, 2, 2)));
    });
  });

  group('SceneInspector3D selection, debug drawing & hierarchy summary', () {
    test('tracks selection, renders overlays, and summarizes hierarchy', () {
      final cubeA = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(2)),
        position: Vector3(-3, 0, 0),
      )..addTag3D('hero');
      final cubeB = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(2)),
        position: Vector3(3, 0, 0),
      );
      final instanced =
          InstancedGroup3D(
              mesh: CuboidMesh(size: Vector3.all(1)),
            )
            ..addInstance(transform: Matrix4.identity())
            ..addInstance(transform: Matrix4.translationValues(2, 0, 0));

      final hiddenBranch = Group3D(
        visible: false,
        children: [cubeB],
      );
      final light = LightComponent.directional();
      final debugRenderer = DebugRenderer3D();

      final world = World3D(
        children: [
          Group3D(children: [cubeA, instanced]),
          hiddenBranch,
          light,
          debugRenderer,
        ],
      );

      Component3D? notifiedSelection;
      final inspector = SceneInspector3D(
        onSelectionChanged: (comp) => notifiedSelection = comp,
      );

      // Ray-picking visible cubeA binds gizmo.target automatically.
      final picked = inspector.pickInWorld(
        world,
        _ray(Vector3(-3, 0, 6), Vector3(0, 0, -1)),
      );
      expect(picked, same(cubeA));
      expect(inspector.selected, same(cubeA));
      expect(inspector.gizmo.target, same(cubeA));
      expect(notifiedSelection, same(cubeA));

      // Ray at hidden cubeB misses and clears selection; re-select cubeA.
      expect(
        inspector.pickInWorld(
          world,
          _ray(Vector3(3, 0, 6), Vector3(0, 0, -1)),
        ),
        isNull,
      );
      inspector.select(cubeA);

      // Clicking cubeA's +X gizmo handle preserves cubeA selection!
      expect(
        inspector.pickInWorld(
          world,
          _ray(Vector3(-2.2, 0, 6), Vector3(0, 0, -1)),
        ),
        same(cubeA),
      );

      // Render inspector + gizmo Across all 3 modes into DebugRenderer3D.
      for (final mode in GizmoMode3D.values) {
        debugRenderer.clearCustomSegments();
        inspector.gizmo.mode = mode;
        inspector.render(debugRenderer, cameraPosition: Vector3(-3, 2, 8));
      }

      // Hierarchy summary counts visible/hidden nodes, instances & triangles.
      final summaryHidden = inspector.summarize(world);
      // Nodes: outer Group3D (0), cubeA (1), instanced (1), hiddenBranch (0),
      // cubeB (1), light (0) -> total 6, visible 4, hidden 2.
      expect(summaryHidden.totalNodes, 6);
      expect(summaryHidden.visibleNodes, 4);
      expect(summaryHidden.hiddenNodes, 2);
      expect(summaryHidden.lightNodeCount, 1);
      expect(summaryHidden.groupNodeCount, 2);
      expect(summaryHidden.meshNodeCount, 3);
      expect(summaryHidden.maxDepth, 1);
      // Visible instances: cubeA (1) + instanced (2) = 3; cuboid = 12 tris.
      expect(summaryHidden.estimatedInstances, 3);
      expect(summaryHidden.estimatedTriangles, 36);

      // Unhiding hiddenBranch adds cubeB (1 instance, 12 triangles).
      hiddenBranch.visible = true;
      final summaryAll = inspector.summarize(world);
      expect(summaryAll.visibleNodes, 6);
      expect(summaryAll.hiddenNodes, 0);
      expect(summaryAll.estimatedInstances, 4);
      expect(summaryAll.estimatedTriangles, 48);
    });
  });
}

Ray _ray(Vector3 origin, Vector3 direction) {
  return Ray.originDirection(origin, direction.normalized());
}
