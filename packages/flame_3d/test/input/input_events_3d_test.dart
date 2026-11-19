import 'dart:ui' show Rect;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart' show CullMode, RenderContext;
import 'package:flame_3d/input.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _InteractiveBox({
  required super.mesh,
  super.position,
  final bool consumeEvents = false,
}) extends MeshComponent
    with TapCallbacks3D, HoverCallbacks3D, DragCallbacks3D {
  final List<String> log = [];
  final List<PointerEvent3D> receivedEvents = [];

  @override
  void onTapDown3D(TapDownEvent3D event) {
    log.add('tapDown');
    receivedEvents.add(event);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onTapUp3D(TapUpEvent3D event) {
    log.add('tapUp');
    receivedEvents.add(event);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onTapCancel3D(TapCancelEvent3D event) {
    log.add('tapCancel');
    receivedEvents.add(event);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onHoverEnter3D(HoverEnterEvent3D event) {
    log.add('hoverEnter');
    receivedEvents.add(event);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onHoverMove3D(HoverMoveEvent3D event) {
    log.add('hoverMove');
    receivedEvents.add(event);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onHoverExit3D(HoverExitEvent3D event) {
    log.add('hoverExit');
    receivedEvents.add(event);
  }

  @override
  void onDragStart3D(DragStartEvent3D event) {
    log.add('dragStart');
    receivedEvents.add(event);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onDragUpdate3D(DragUpdateEvent3D event) {
    log.add('dragUpdate');
    receivedEvents.add(event);
    position.add(event.worldDelta);
    if (consumeEvents) {
      event.handled = true;
    }
  }

  @override
  void onDragEnd3D(DragEndEvent3D event) {
    log.add('dragEnd');
    receivedEvents.add(event);
  }
}

class _InteractiveContainer({super.children})
    extends Object3D
    with TapCallbacks3D, HoverCallbacks3D {
  final List<String> log = [];

  @override
  void draw(RenderContext context) {}

  @override
  void onTapDown3D(TapDownEvent3D event) => log.add('parentTapDown');

  @override
  void onTapUp3D(TapUpEvent3D event) => log.add('parentTapUp');

  @override
  void onTapCancel3D(TapCancelEvent3D event) => log.add('parentTapCancel');

  @override
  void onHoverEnter3D(HoverEnterEvent3D event) => log.add('parentHoverEnter');

  @override
  void onHoverMove3D(HoverMoveEvent3D event) => log.add('parentHoverMove');

  @override
  void onHoverExit3D(HoverExitEvent3D event) => log.add('parentHoverExit');
}

class _PickableInstancedGroup({required super.mesh})
    extends InstancedGroup3D
    with TapCallbacks3D, HoverCallbacks3D, DragCallbacks3D {
  final List<int?> tappedInstances = [];
  final List<int?> hoveredInstances = [];
  final List<(int?, Vector3)> draggedInstances = [];

  @override
  void onTapDown3D(TapDownEvent3D event) {
    tappedInstances.add(event.instanceIndex);
  }

  @override
  void onHoverEnter3D(HoverEnterEvent3D event) {
    hoveredInstances.add(event.instanceIndex);
  }

  @override
  void onHoverMove3D(HoverMoveEvent3D event) {
    hoveredInstances.add(event.instanceIndex);
  }

  @override
  void onDragUpdate3D(DragUpdateEvent3D event) {
    draggedInstances.add((event.instanceIndex, event.worldDelta.clone()));
  }
}

class _UpConsumingBox({required super.mesh})
    extends MeshComponent
    with TapCallbacks3D {
  final List<String> log = [];

  @override
  void onTapDown3D(TapDownEvent3D event) => log.add('tapDown');

  @override
  void onTapUp3D(TapUpEvent3D event) {
    log.add('tapUp');
    event.handled = true;
  }

  @override
  void onTapCancel3D(TapCancelEvent3D event) => log.add('tapCancel');
}

void main() {
  group('PointerRouter3D event closure and per-pointer state', () {
    test('a listener left out of a handled tap up gets a cancel', () {
      final child = _UpConsumingBox(mesh: CuboidMesh(size: Vector3.all(2)));
      final parent = _InteractiveContainer(children: [child]);
      final world = World3D(children: [parent]);
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 10),
        target: Vector3.zero(),
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );
      final center = camera.worldToViewportPoint(Vector3.zero());
      router
        ..dispatchTapDown(center)
        ..dispatchTapUp(center);
      expect(child.log, ['tapDown', 'tapUp']);
      expect(parent.log, ['parentTapDown', 'parentTapCancel']);
    });

    test('each pointer has its own hover state', () {
      final cube = CuboidMesh(size: Vector3.all(2));
      final left = _InteractiveBox(mesh: cube, position: Vector3(-3, 0, 0));
      final right = _InteractiveBox(mesh: cube, position: Vector3(3, 0, 0));
      final world = World3D(children: [left, right]);
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 12),
        target: Vector3.zero(),
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );
      router
        ..dispatchHover(camera.worldToViewportPoint(Vector3(-3, 0, 0)))
        ..dispatchHover(
          camera.worldToViewportPoint(Vector3(3, 0, 0)),
          pointerId: 7,
        );
      expect(left.log, ['hoverEnter']);
      expect(right.log, ['hoverEnter']);

      router.dispatchHover(Vector2(5, 5), pointerId: 7);
      expect(right.log, ['hoverEnter', 'hoverExit']);
      expect(left.log, ['hoverEnter']);

      router.dispatchHoverExit(pointerId: null);
      expect(left.log, ['hoverEnter', 'hoverExit']);
    });

    test('a forScene perspective drag ignores plane hits behind the eye', () {
      final box = _InteractiveBox(mesh: CuboidMesh(size: Vector3.all(1)));
      final scene = Scene3DComponent(
        projection: Scene3DProjection.perspective(
          eye: Vector3(0, -10, 5),
          target: Vector3.zero(),
          rect: const Rect.fromLTWH(0, 0, 800, 600),
        ),
      );
      scene.world.add(box);
      final router = PointerRouter3D.forScene(
        scene,
        cullMode: CullMode.none,
        defaultDragNormal: Vector3(0, 0, 1),
      );
      final onBox = scene.scenePointToLocal(Vector3(0, 0, 0.5));
      expect(router.dispatchDragStart(onBox), isTrue);
      // Near the top of the picture the line of sight rises: the drag plane
      // (z = 0.5) is behind the eye there.
      expect(router.dispatchDragUpdate(Vector2(400, 5)), isTrue);
      expect(box.position, closeToVector3(Vector3.zero(), 1e-9));
    });
  });

  group('3D Input Events & PointerRouter3D', () {
    test('dispatches tap down, tap up, and off-target tap cancel', () {
      final cube = CuboidMesh(size: Vector3.all(2));
      final box = _InteractiveBox(mesh: cube);
      final world = World3D(children: [box]);
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 10),
        target: Vector3.zero(),
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );

      final center2D = camera.worldToViewportPoint(Vector3.zero());
      final empty2D = Vector2(20, 20);

      expect(router.dispatchTapDown(center2D, pointerId: 1), isTrue);
      expect(router.dispatchTapUp(center2D, pointerId: 1), isTrue);
      expect(box.log, ['tapDown', 'tapUp']);
      expect(box.receivedEvents.first.pointerId, 1);
      expect(box.receivedEvents.first.target, same(box));
      expect(box.receivedEvents.first.instanceIndex, isNull);

      box.log.clear();
      expect(router.dispatchTapDown(center2D, pointerId: 2), isTrue);
      expect(router.dispatchTapUp(empty2D, pointerId: 2), isTrue);
      expect(box.log, ['tapDown', 'tapCancel']);
    });

    test('stops ancestor propagation when event.handled is true', () {
      final cube = CuboidMesh(size: Vector3.all(2));
      final bubblingChild = _InteractiveBox(
        mesh: cube,
        position: Vector3(-2, 0, 0),
      );
      final consumingChild = _InteractiveBox(
        mesh: cube,
        position: Vector3(2, 0, 0),
        consumeEvents: true,
      );
      final parentGroup = _InteractiveContainer(
        children: [bubblingChild, consumingChild],
      );
      final world = World3D(children: [parentGroup]);
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 12),
        target: Vector3.zero(),
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );

      final leftPt = camera.worldToViewportPoint(Vector3(-2, 0, 0));
      router.dispatchTapDown(leftPt);
      router.dispatchTapUp(leftPt);
      expect(bubblingChild.log, ['tapDown', 'tapUp']);
      expect(parentGroup.log, ['parentTapDown', 'parentTapUp']);

      parentGroup.log.clear();
      final rightPt = camera.worldToViewportPoint(Vector3(2, 0, 0));
      router.dispatchTapDown(rightPt);
      router.dispatchTapUp(rightPt);
      expect(consumingChild.log, ['tapDown', 'tapUp']);
      expect(parentGroup.log, isEmpty);
    });

    test('tracks hover enter, move, target switch exit->enter, and exit', () {
      final eventOrder = <String>[];
      final cube = CuboidMesh(size: Vector3.all(2));
      final leftBox = _InteractiveBox(
        mesh: cube,
        position: Vector3(-3, 0, 0),
      );
      final rightBox = _InteractiveBox(
        mesh: cube,
        position: Vector3(3, 0, 0),
      );

      final world = World3D(children: [leftBox, rightBox]);
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 12),
        target: Vector3.zero(),
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );

      final leftCenter = camera.worldToViewportPoint(Vector3(-3, 0, 0));
      final leftNudge = camera.worldToViewportPoint(Vector3(-2.6, 0.2, 0));
      final rightCenter = camera.worldToViewportPoint(Vector3(3, 0, 0));
      final missPt = Vector2(5, 5);

      router.dispatchHover(leftCenter);
      expect(leftBox.log, ['hoverEnter']);

      router.dispatchHover(leftNudge);
      expect(leftBox.log, ['hoverEnter', 'hoverMove']);

      final leftCountBefore = leftBox.log.length;
      router.dispatchHover(rightCenter);
      if (leftBox.log.length > leftCountBefore) {
        eventOrder.add('left:${leftBox.log.last}');
      }
      if (rightBox.log.isNotEmpty) {
        eventOrder.add('right:${rightBox.log.last}');
      }
      expect(leftBox.log, ['hoverEnter', 'hoverMove', 'hoverExit']);
      expect(rightBox.log, ['hoverEnter']);
      expect(eventOrder, ['left:hoverExit', 'right:hoverEnter']);

      router.dispatchHover(missPt);
      expect(rightBox.log, ['hoverEnter', 'hoverExit']);
    });

    test('projects 3D ray-plane drag onto configured ground plane', () {
      final cube = CuboidMesh(size: Vector3.all(2));
      final piece = _InteractiveBox(mesh: cube)
        ..dragPlaneNormal = Vector3(0, 1, 0);
      final world = World3D(children: [piece]);
      final camera = CameraComponent3D(
        position: Vector3(0, 10, 10),
        target: Vector3.zero(),
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );

      final startScreen = camera.worldToViewportPoint(Vector3(0, 1, 0));
      final destWorldOnPlane = Vector3(4, 1, -2);
      final destScreen = camera.worldToViewportPoint(destWorldOnPlane);

      expect(router.dispatchDragStart(startScreen), isTrue);
      expect(router.dispatchDragUpdate(destScreen), isTrue);
      expect(router.dispatchDragEnd(point: destScreen), isTrue);

      expect(piece.log, ['dragStart', 'dragUpdate', 'dragEnd']);
      expect(piece.position, closeToVector3(Vector3(4, 0, -2), 1e-3));
    });

    test('projects 1D axis-constrained gizmo drag strictly onto axis', () {
      final cube = CuboidMesh(size: Vector3(2, 0.5, 0.5));
      final gizmoX = _InteractiveBox(mesh: cube)
        ..dragAxisConstraint = Vector3(1, 0, 0);
      final world = World3D(children: [gizmoX]);
      final camera = CameraComponent3D(
        position: Vector3(0, 4, 12),
        target: Vector3.zero(),
        projection: CameraProjection.orthographic,
        orthographicHeight: 12,
        viewport: FixedSizeViewport(800, 600),
      );
      final router = PointerRouter3D.forCamera(
        world: world,
        camera: camera,
        cullMode: CullMode.none,
      );

      final grabScreen = camera.worldToViewportPoint(Vector3(0.4, 0.1, 0));
      final diagScreen = camera.worldToViewportPoint(Vector3(3.4, 2.8, 0));

      expect(router.dispatchDragStart(grabScreen), isTrue);
      expect(gizmoX.position, closeToVector3(Vector3.zero(), 1e-5));

      expect(router.dispatchDragUpdate(diagScreen), isTrue);
      expect(router.dispatchDragEnd(), isTrue);

      expect(gizmoX.position.x, closeTo(3.0, 1e-3));
      expect(gizmoX.position.y, closeTo(0.0, 1e-5));
      expect(gizmoX.position.z, closeTo(0.0, 1e-5));
    });

    test(
      'picks InstancedGroup3D instanceIndex via Scene3DComponent router',
      () {
        final group = _PickableInstancedGroup(
          mesh: CuboidMesh(size: Vector3.all(1)),
        )..dragPlaneNormal = Vector3(0, 0, 1);
        group
          ..addInstance(transform: Matrix4.translationValues(0, 0, 0))
          ..addInstance(transform: Matrix4.translationValues(4, 0, 0))
          ..addInstance(transform: Matrix4.translationValues(0, 4, 0));

        final scene = Scene3DComponent(
          projection: Scene3DProjection.affine(
            origin: Vector2(200, 200),
            xAxis: Vector2(32, 16),
            yAxis: Vector2(-32, 16),
            zAxis: Vector2(0, -32),
            towardsViewer: Vector3(1, 1, 1),
            near: -60,
            far: 60,
          ),
        );
        scene.world.add(group);

        final router = PointerRouter3D.forScene(
          scene,
          cullMode: CullMode.none,
        );

        final inst1Pt = scene.scenePointToLocal(Vector3(4, 0, 0));
        final inst2Pt = scene.scenePointToLocal(Vector3(0, 4, 0));

        expect(router.dispatchTapDown(inst1Pt), isTrue);
        expect(router.dispatchTapUp(inst1Pt), isTrue);
        expect(group.tappedInstances, [1]);

        router.dispatchHover(inst1Pt);
        router.dispatchHover(inst2Pt);
        expect(group.hoveredInstances, [1, 2]);

        final movedPt = scene.scenePointToLocal(Vector3(2, 6, 0));
        expect(router.dispatchDragStart(inst2Pt), isTrue);
        expect(router.dispatchDragUpdate(movedPt), isTrue);
        expect(router.dispatchDragEnd(), isTrue);

        expect(group.draggedInstances, hasLength(1));
        expect(group.draggedInstances.single.$1, 2);
        expect(
          group.draggedInstances.single.$2,
          closeToVector3(Vector3(2, 2, 0), 1e-3),
        );
      },
    );

    testWithFlameGame(
      'mounts cleanly inside a FlameGame with input dispatchers',
      (game) async {
        final box = _InteractiveBox(mesh: CuboidMesh(size: Vector3.all(2)));
        final world3D = World3D(children: [box]);
        final cam3D = CameraComponent3D(
          position: Vector3(0, 0, 8),
          target: Vector3.zero(),
          viewport: FixedSizeViewport(800, 600),
        );
        final router = PointerRouter3D.forCamera(
          world: world3D,
          camera: cam3D,
          size: Vector2(800, 600),
          cullMode: CullMode.none,
        );
        await game.ensureAdd(router);

        final tapPos = cam3D.worldToViewportPoint(Vector3.zero());
        router.dispatchTapDown(tapPos);
        router.dispatchTapUp(tapPos);
        expect(box.log, ['tapDown', 'tapUp']);
      },
    );
  });
}
