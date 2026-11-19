import 'dart:math' as math;
import 'dart:ui' show Color, Size;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

final bool _gpuAvailable = GpuBackend.isAvailable;

void _setUpGpu() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_gpuAvailable) {
      await GpuBackend.initialize();
    }
  });
}

@isTest
void _testGpuEngine(String description, Future<void> Function() body) {
  test(
    description,
    body,
    skip: _gpuAvailable
        ? false
        : 'Flutter GPU unavailable; run with '
              '--enable-impeller --enable-flutter-gpu',
  );
}

CameraComponent3D _makePerspectiveCamera({
  required Vector3 position,
  required Vector3 target,
  double fovY = 60,
  double near = 0.5,
  double far = 256,
}) {
  return CameraComponent3D(
    position: position,
    target: target,
    fovY: fovY,
    near: near,
    far: far,
    viewport: FixedResolutionViewport(resolution: Vector2(256, 128)),
  );
}

void main() {
  _setUpGpu();

  group('LightClusterGrid3D (128+ Clustered Forward+ Lights)', () {
    test(
      'slices depth exponentially and assigns 200 point and spot lights',
      () {
        final grid = LightClusterGrid3D();
        expect(grid.totalClusters, 16 * 8 * 16);

        final camera = _makePerspectiveCamera(
          position: Vector3(0, 2, 0),
          target: Vector3(0, 2, -50),
          near: 1.0,
        );

        // Register 160 point lights + 40 spot lights = 200 lights across the
        // frustum and outside it.
        for (var i = 0; i < 160; i++) {
          final col = i % 10;
          final row = (i ~/ 10) % 4;
          final layer = i ~/ 40;
          final x = -18.0 + col * 4.0;
          final y = -2.0 + row * 3.0;
          final z = -4.0 - layer * 25.0;
          grid.addLight(
            ClusterLightEntry3D.point(
              position: Vector3(x, y, z),
              range: 4.5,
              color: const Color(0xFFFFA040),
              intensity: 2.0 + (i % 5) * 0.5,
            ),
          );
        }
        for (var s = 0; s < 40; s++) {
          final x = -15.0 + (s % 8) * 4.2;
          final z = -8.0 - (s ~/ 8) * 18.0;
          grid.addLight(
            ClusterLightEntry3D.spot(
              position: Vector3(x, 6, z),
              direction: Vector3(0, -1, 0),
              range: 10.0,
              innerConeAngle: math.pi / 10,
              outerConeAngle: math.pi / 5,
              color: const Color(0xFF40D0FF),
              intensity: 3.5,
            ),
          );
        }
        expect(grid.lightCount, 200);

        grid.assignLights(
          camera.viewMatrix,
          camera.projectionMatrix,
          near: 1.0,
          far: 256.0,
        );

        expect(grid.totalAssignedLightRefs, greaterThan(200));

        // Verify exponential depth slicing formula:
        // zSlice = floor(log(viewZ / near) / log(far / near) * 16).
        // With near = 1, far = 256 (2^8), each slice multiplies depth by 2^0.5:
        // viewDepth = 1 -> slice 0, viewDepth = 16 (2^4) -> slice 8,
        // viewDepth = 255 -> slice 15.
        expect(grid.zSliceForViewDepth(1.0), 0);
        expect(grid.zSliceForViewDepth(16.1), 8);
        expect(grid.zSliceForViewDepth(255.0), 15);

        // Center screen at depth 4.0 should contain nearby front-layer lights
        // and exclude distant z = -79 lights.
        final nearCenterCluster = grid.clusterIndexForScreenDepth(
          0.5,
          0.5,
          4.0,
        );
        final nearAssigned = grid.lightsForCluster(nearCenterCluster);
        expect(nearAssigned, isNotEmpty);
        for (final idx in nearAssigned) {
          final light = grid.lightAt(idx);
          expect(light.position.z, greaterThan(-20.0));
        }

        // Pack RGBA8 cluster table and verify offsets/counts round-trip.
        final packed = grid.packClusterDataRgba8();
        expect(packed.length, grid.totalClusters * 4);
        final b = nearCenterCluster * 4;
        final unpackedOffset = packed[b] | (packed[b + 1] << 8);
        final unpackedCount = packed[b + 2];
        expect(unpackedOffset, grid.clusterOffsets[nearCenterCluster]);
        expect(unpackedCount, nearAssigned.length);
      },
    );

    test('culls spotlight clusters behind apex and ranks top AABB lights', () {
      final grid = LightClusterGrid3D();
      final camera = _makePerspectiveCamera(
        position: Vector3.zero(),
        target: Vector3(0, 0, -40),
        far: 100.0,
      );

      // Spotlight at z = -20 pointing straight away (-Z): clusters in front of
      // z = -20 (closer to camera, e.g. depth = 10) must NOT receive it!
      final forwardSpot = grid.addLight(
        ClusterLightEntry3D.spot(
          position: Vector3(0, 0, -20),
          direction: Vector3(0, 0, -1),
          range: 18.0,
          innerConeAngle: math.pi / 12,
          outerConeAngle: math.pi / 6,
          intensity: 5.0,
        ),
      );

      // Add 12 point lights on a unit circle around (0, 0, -10) with strictly
      // increasing intensities so distance to (0, 0, -10) is equal for all 12.
      var brightestIdx = -1;
      for (var i = 0; i < 12; i++) {
        final angle = i * (math.pi * 2 / 12);
        final intensity = (i + 1) * 1.5;
        final id = grid.addLight(
          ClusterLightEntry3D.point(
            position: Vector3(math.cos(angle), math.sin(angle), -10),
            range: 6.0,
            intensity: intensity,
          ),
        );
        if (i == 11) {
          brightestIdx = id;
        }
      }

      grid.assignLights(
        camera.viewMatrix,
        camera.projectionMatrix,
        near: 0.5,
        far: 100.0,
      );

      final behindApexCluster = grid.clusterIndexForScreenDepth(0.5, 0.5, 10.0);
      final inConeCluster = grid.clusterIndexForScreenDepth(0.5, 0.5, 28.0);
      expect(
        grid.lightsForCluster(behindApexCluster).contains(forwardSpot),
        isFalse,
      );
      expect(
        grid.lightsForCluster(inConeCluster).contains(forwardSpot),
        isTrue,
      );

      final topAtTen = grid.gatherTopLightsForAabb(
        Aabb3.minMax(Vector3(-1, -1, -11), Vector3(1, 1, -9)),
        camera.viewMatrix,
        maxPointLights: 4,
        maxSpotLights: 2,
      );
      expect(topAtTen.pointLightIndices.length, 4);
      expect(topAtTen.pointLightIndices.first, brightestIdx);
    });
  });

  group('OcclusionCuller3D & PortalOcclusionGraph3D', () {
    test('Hi-Z culls AABBs hidden behind walls while keeping visible ones', () {
      final culler = OcclusionCuller3D();
      final camera = _makePerspectiveCamera(
        position: Vector3(0, 2, 0),
        target: Vector3(0, 2, -30),
        far: 120.0,
      );
      final vp = camera.viewProjectionMatrix;

      // Solid castle wall spanning x in [-8, 8], y in [-2, 4.5] at z = -10,
      // plus a solid tower box on the right.
      culler
        ..addQuad(
          OccluderQuad3D.wall(
            bottomStart: Vector3(-8, -2, -10),
            bottomEnd: Vector3(8, -2, -10),
            height: 6.5,
          ),
        )
        ..addBox(
          OccluderBox3D(
            center: Vector3(10, 2, -12),
            halfExtents: Vector3(3, 5, 2),
          ),
        )
        ..rasterizeOccluders(vp);

      expect(culler.rasterizedOccluderCount, 2);

      // 1. Crate completely behind the wall at z = -22 (y in [0.5, 3.0], below
      // the camera->wall-top sightline y = 2 + 20 * 0.25 = 7.0) -> OCCLUDED!
      final hiddenBehindWall = Aabb3.minMax(
        Vector3(-1.5, 0.5, -24),
        Vector3(1.5, 3.0, -20),
      );
      expect(culler.isAabbVisible(hiddenBehindWall, vp), isFalse);

      // 2. Crate in front of the wall at z = -5 -> VISIBLE!
      final inFrontOfWall = Aabb3.minMax(
        Vector3(-1, 1, -6),
        Vector3(1, 3, -4),
      );
      expect(culler.isAabbVisible(inFrontOfWall, vp), isTrue);

      // 3. Tall spire sticking UP above the wall's perspective sightline at
      // z = -18 (wall top at z = -10 projects to y = 2 + 18 * 0.25 = 6.5, and
      // spire reaches y = 9.5) -> MUST stay VISIBLE (never falsely culled)!
      final peekingOverWall = Aabb3.minMax(
        Vector3(-1, 0, -20),
        Vector3(1, 9.5, -18),
      );
      expect(culler.isAabbVisible(peekingOverWall, vp), isTrue);

      // 4. Object straddling the camera near plane -> conservatively VISIBLE!
      final straddlingNear = Aabb3.minMax(
        Vector3(-0.5, 1, -2),
        Vector3(0.5, 3, 1),
      );
      expect(culler.isAabbVisible(straddlingNear, vp), isTrue);

      expect(culler.testedCount, 4);
      expect(culler.occludedCount, 1);
    });

    test('PortalOcclusionGraph3D narrows scissors and culls closed doors', () {
      final graph = PortalOcclusionGraph3D()
        // Room 0: camera room z in [-10, 10]
        ..addRoom(
          OcclusionRoom3D(
            id: 0,
            bounds: Aabb3.minMax(Vector3(-10, 0, -10), Vector3(10, 6, 10)),
            name: 'EntryHall',
          ),
        )
        // Room 1: straight ahead z in [-30, -10]
        ..addRoom(
          OcclusionRoom3D(
            id: 1,
            bounds: Aabb3.minMax(Vector3(-10, 0, -30), Vector3(10, 6, -10)),
            name: 'Corridor',
          ),
        )
        // Room 2: aligned beyond Room 1 z in [-50, -30]
        ..addRoom(
          OcclusionRoom3D(
            id: 2,
            bounds: Aabb3.minMax(Vector3(-10, 0, -50), Vector3(10, 6, -30)),
            name: 'Sanctum',
          ),
        )
        // Room 3: side annex reachable only through an off-axis doorway that
        // does NOT align with Portal 0->1 from the camera's viewpoint!
        ..addRoom(
          OcclusionRoom3D(
            id: 3,
            bounds: Aabb3.minMax(Vector3(10, 0, -30), Vector3(25, 6, -10)),
            name: 'SideVault',
          ),
        );

      // Narrow center doorway between Room 0 and Room 1: x in [-1.2, 1.2].
      final door01 = OcclusionPortal3D.rect(
        roomA: 0,
        roomB: 1,
        bottomStart: Vector3(-1.2, 0, -10),
        bottomEnd: Vector3(1.2, 0, -10),
        height: 3.5,
      );
      // Aligned center doorway between Room 1 and Room 2: x in [-1.0, 1.0].
      final door12 = OcclusionPortal3D.rect(
        roomA: 1,
        roomB: 2,
        bottomStart: Vector3(-1, 0, -30),
        bottomEnd: Vector3(1, 0, -30),
        height: 3.5,
      );
      // Side doorway on far right wall of Room 1 at x = 10, z in [-18, -15]:
      // outside the narrow center scissor projected through door01!
      final door13Misaligned = OcclusionPortal3D.rect(
        roomA: 1,
        roomB: 3,
        bottomStart: Vector3(10, 0, -18),
        bottomEnd: Vector3(10, 0, -15),
        height: 3.5,
      );

      graph
        ..addPortal(door01)
        ..addPortal(door12)
        ..addPortal(door13Misaligned);

      final camera = _makePerspectiveCamera(
        position: Vector3(0, 1.8, 0),
        target: Vector3(0, 1.8, -40),
      );
      final vp = camera.viewProjectionMatrix;

      graph.evaluateVisibility(
        cameraPosition: camera.position,
        viewProjection: vp,
      );

      expect(graph.isRoomVisible(0), isTrue);
      expect(graph.isRoomVisible(1), isTrue);
      expect(graph.isRoomVisible(2), isTrue);
      // Misaligned side room cannot be seen through narrow door01!
      expect(graph.isRoomVisible(3), isFalse);

      // Scissor narrows progressively from Room 0 -> Room 1 -> Room 2.
      final s0 = graph.roomScissor(0)!;
      final s1 = graph.roomScissor(1)!;
      final s2 = graph.roomScissor(2)!;
      expect(s1.maxX - s1.minX, lessThan(s0.maxX - s0.minX));
      expect(s2.maxX - s2.minX, lessThan(s1.maxX - s1.minX));

      // Object in Room 1 far off to x = -8 is outside Room 1's portal scissor!
      expect(
        graph.isAabbVisibleInRoom(
          1,
          Aabb3.minMax(Vector3(-9, 0.5, -20), Vector3(-7.5, 2.5, -18)),
          vp,
        ),
        isFalse,
      );
      // Object in Room 2 dead-ahead at x = 0 IS visible through both portals!
      expect(
        graph.isAabbVisibleInRoom(
          2,
          Aabb3.minMax(Vector3(-0.4, 0.5, -36), Vector3(0.4, 2.5, -34)),
          vp,
        ),
        isTrue,
      );

      // Closing door01 culls both Room 1 and Room 2 immediately!
      door01.isOpen = false;
      graph.evaluateVisibility(
        cameraPosition: camera.position,
        viewProjection: vp,
      );
      expect(graph.isRoomVisible(0), isTrue);
      expect(graph.isRoomVisible(1), isFalse);
      expect(graph.isRoomVisible(2), isFalse);
    });
  });

  group('StaticMeshBatcher3D (200 Heterogeneous Meshes & Surgical Slots)', () {
    test(
      'merges 200 diverse meshes into spatial chunks and hides slots in O(1)',
      () {
        final sharedMaterial = UnlitMaterial()
          ..renderState = RenderState.opaque;

        final cube = CuboidMesh(
          size: Vector3.all(0.8),
          material: sharedMaterial,
        );
        final sphere = SphereMesh(
          radius: 0.45,
          segments: 8,
          material: sharedMaterial,
        );
        final cone = ConeMesh(
          radius: 0.4,
          height: 0.9,
          material: sharedMaterial,
        );
        final variants = <Mesh>[cube, sphere, cone];

        final batcher = StaticMeshBatcher3D(chunkSize: 64.0);
        final slots = <int>[];

        // Place all 200 heterogeneous props inside a single 64m spatial chunk
        // `[0..30] x [0..2] x [-30..-2]`.
        for (var i = 0; i < 200; i++) {
          final mesh = variants[i % variants.length];
          final gx = (i % 20) * 1.4;
          final gz = -2.0 - (i ~/ 20) * 2.4;
          final tf = Matrix4.identity()
            ..translateByDouble(gx, 0.5, gz, 1)
            ..rotateY(i * 0.25);
          slots.add(
            batcher.addStaticInstance(
              mesh: mesh,
              transform: tf,
              color: Color.from(
                alpha: 1,
                red: 0.3 + (i % 7) * 0.1,
                green: 0.6,
                blue: 0.8,
              ),
            ),
          );
        }

        batcher.bakeDirtyChunks();
        expect(batcher.activeSlotCount, 200);
        expect(batcher.chunkCount, 1);
        expect(batcher.surfaceBatchCount, 1);
        expect(batcher.fullBakeCount, 1);

        // Raycast straight down onto slot 0 at (0, 0.5, -2) hits before hiding,
        // and misses after surgical `setSlotVisible(slot0, visible: false)`!
        final rayDown = Ray.originDirection(
          Vector3(0, 5, -2),
          Vector3(0, -1, 0),
        );
        expect(batcher.raycast(rayDown), isNotNull);

        batcher.setSlotVisible(slots[0], visible: false);
        expect(batcher.isSlotVisible(slots[0]), isFalse);
        // Zero full chunk re-bakes: handled surgically via index toggling!
        expect(batcher.fullBakeCount, 1);
        expect(batcher.surgicalUpdateCount, 1);
        expect(batcher.raycast(rayDown), isNull);

        // Restore visibility surgically and verify raycast hits again.
        batcher.setSlotVisible(slots[0], visible: true);
        expect(batcher.raycast(rayDown), isNotNull);
        expect(batcher.fullBakeCount, 1);
        expect(batcher.surgicalUpdateCount, 2);

        // Permanent slot removal also updates indices without re-transforming.
        expect(batcher.removeSlot(slots[0]), isTrue);
        expect(batcher.activeSlotCount, 199);
        expect(batcher.raycast(rayDown), isNull);
        batcher.clear();
      },
    );

    _testGpuEngine(
      'draws 200 heterogeneous static meshes in 1 GPU draw call',
      () async {
        final mat = UnlitMaterial()..renderState = RenderState.opaque;
        final cube = CuboidMesh(size: Vector3.all(0.5), material: mat);
        final cone = ConeMesh(radius: 0.3, height: 0.6, material: mat);
        final batcher = StaticMeshBatcher3D(chunkSize: 64.0);

        for (var i = 0; i < 200; i++) {
          final x = 1.0 + (i % 20) * 0.95;
          final y = 1.0 + (i ~/ 20) * 0.95;
          batcher.addStaticInstance(
            mesh: i.isEven ? cube : cone,
            transform: Matrix4.translationValues(x, y, -18),
            color: const Color(0xFF40E080),
          );
        }

        final world = World3D(children: [batcher]);
        final camera = _makePerspectiveCamera(
          position: Vector3(10, 5, 0),
          target: Vector3(10, 5, -18),
        );
        final device = GraphicsDevice();
        final context = RenderContext3D(device);
        device.begin();
        final image = world.renderToImage(
          const Size(128, 128),
          view: camera.viewMatrix,
          projection: camera.projectionMatrix,
          device: device,
          context: context,
        );
        device.end();
        addTearDown(image.dispose);

        expect(device.lastFrameStats.drawCalls, 1);
        expect(batcher.lastDrawnBatchCount, 1);
      },
    );
  });

  group(
    'FloatingOriginController3D & WorldPosition64 (1,000,000 m Precision)',
    () {
      test(
        'maintains < 1e-4 sub-millimeter precision at (1000000, 0, -1000000)',
        () async {
          final camera = _makePerspectiveCamera(
            position: Vector3.zero(),
            target: Vector3(0, 0, -10),
          );

          final shiftEvents = <Vector3>[];
          final controller = FloatingOriginController3D(
            camera: camera,
            onOriginShifted: (delta) => shiftEvents.add(delta.clone()),
          );

          // Place a landmark prop at exact 64-bit world coordinate
          // `(1_000_003.1234, 1.75, -999_996.4321)`.
          final landmarkWorld = WorldPosition64(
            1000003.1234,
            1.75,
            -999996.4321,
          );
          final landmarkNode = MeshComponent(
            mesh: CuboidMesh(size: Vector3.all(1)),
          );
          final landmarkBinding = FloatingOriginTransform3D(
            worldPosition: landmarkWorld,
            target: landmarkNode,
          );
          controller.register(landmarkBinding);

          // Simulate travelling 400 steps of (2500, 0, -2500) -> reaching exact
          // world `(1_000_000.0, 0.0, -1_000_000.0)`!
          final particleLocalPos = Vector3(1000003.1234, 1.75, -999996.4321);
          controller.addOriginShiftListener(particleLocalPos.add);

          for (var step = 0; step < 400; step++) {
            camera.position.add(Vector3(2500, 0, -2500));
            camera.target.add(Vector3(2500, 0, -2500));
            controller.update(0.016);
          }

          expect(controller.rebaseCount, 400);
          expect(shiftEvents.length, 400);
          expect(controller.originX, 1000000.0);
          expect(controller.originY, 0.0);
          expect(controller.originZ, -1000000.0);

          // Camera was rebased back to local (0, 0, 0), and its 64-bit world
          // coordinate is exact!
          expect(camera.position.length, lessThan(1e-6));
          final camWorld64 = controller.cameraWorldPosition64();
          expect(
            camWorld64.distanceTo(WorldPosition64(1000000, 0, -1000000)),
            0,
          );

          // Verify sub-millimeter (`< 1e-4` m) local precision of the landmark!
          // Exact expected offset from `(1_000_000, 0, -1_000_000)`:
          // `(3.1234, 1.75, 3.5679)`.
          expect((landmarkNode.position.x - 3.1234).abs(), lessThan(1e-4));
          expect((landmarkNode.position.y - 1.75).abs(), lessThan(1e-4));
          expect((landmarkNode.position.z - 3.5679).abs(), lessThan(1e-4));
        },
      );
    },
  );
}
