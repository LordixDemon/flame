import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas, Color, PictureRecorder, Size;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/collisions/collision_manifold_3d.dart'
    show MutableManifoldBuffer3D;
import 'package:flame_3d/world_scale.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show Frustum, makePerspectiveMatrix, makeViewMatrix;

import '../_fakes/fake_gpu_backend.dart';

class _CountingObject3D({
  required Vector3 halfExtents,
  super.position,
}) extends Object3D {
  final Aabb3 _localBounds = Aabb3.minMax(
    Vector3(-halfExtents.x, -halfExtents.y, -halfExtents.z),
    Vector3(halfExtents.x, halfExtents.y, halfExtents.z),
  );
  int mainDraws = 0;
  int shadowDraws = 0;

  @override
  Aabb3? computeLocalAabb() => _localBounds;

  @override
  void draw(covariant RenderContext3D context) {
    if (context.isShadowPass) {
      shadowDraws++;
    } else {
      mainDraws++;
    }
  }
}

Model _riggedSampleModel() {
  final skinnedMat = StylizedMaterial();
  final baseSkinned = StylizedMaterial.buildSurface(
    positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
    normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
    indices: const [0, 1, 2],
    joints: const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    weights: const [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
    material: skinnedMat,
  );
  final skinnedSurf = Surface.fromBuffers(
    vertices: baseSkinned.vertexData,
    indices: baseSkinned.indices,
    layout: baseSkinned.layout,
    material: skinnedMat,
    jointMap: const {0: 0},
  );
  final skinnedMesh = Mesh()..addSurface(skinnedSurf);
  final helmetMesh = CuboidMesh(
    size: Vector3.all(0.4),
    material: SpatialMaterial(),
  );
  final clip = ModelAnimation(
    name: 'idle',
    nodes: {
      0: NodeAnimation(
        channels: [
          AnimationController(
            animation: TranslationAnimationSpline.from(
              interpolation: AnimationInterpolation.linear,
              times: [0.0, 2.0],
              values: [Vector3.zero(), Vector3(0, 0, 2)],
            ),
          ),
        ],
      ),
    },
  );
  return Model(
    nodes: {
      0: ModelNode(
        name: 'Root',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: Matrix4.identity(),
        mesh: null,
        joints: const {},
      ),
      1: ModelNode(
        name: 'Body',
        nodeIndex: 1,
        parentNodeIndex: null,
        transform: Matrix4.identity(),
        mesh: skinnedMesh,
        joints: {
          0: ModelJoint(
            nodeIndex: 0,
            inverseBindMatrix: Matrix4.identity(),
          ),
        },
      ),
      2: ModelNode(
        name: 'Helmet',
        nodeIndex: 2,
        parentNodeIndex: 0,
        transform: Matrix4.translationValues(0, 1.5, 0),
        mesh: helmetMesh,
        joints: const {},
      ),
    },
    animations: [clip],
  );
}

void main() {
  group('SkinnedCrowdBatch3D pose & handedness bucketing', () {
    test('coalesces shared pose buckets including mirrored agents', () {
      FakeGpuBackend();
      final device = GraphicsDevice();
      final context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());

      final crowd = SkinnedCrowdBatch3D(
        model: _riggedSampleModel(),
        initialCapacity: 24,
      );

      for (var i = 0; i < 20; i++) {
        crowd.addAgent(
          position: Vector3((i % 5) * 2.0, 0, (i ~/ 5) * 2.0),
          scale: i.isOdd ? Vector3(-1, 1, 1) : Vector3(1, 1, 1),
          initialClock: i < 10 ? 0.0 : 0.5,
        );
      }

      crowd.update(0.1);
      crowd.draw(context);

      expect(crowd.lastSkinnedNodeDraws, 20);
      // 2 distinct quantized poses * 2 handedness states (plain & mirrored)
      // coalesce into 4 buckets.
      expect(crowd.lastSkinnedPoseBuckets, 4);
      // Unskinned helmet sub-node coalesces into 1 `drawInstances` call.
      expect(crowd.lastInstancedSubNodeDraws, 1);

      final aabb = crowd.computeLocalAabb();
      expect(aabb, isNotNull);
      expect(aabb!.min.x, lessThanOrEqualTo(0.0));
      expect(aabb.max.x, greaterThanOrEqualTo(8.0));
    });
  });

  group('CrowdSteering3D spatial hash', () {
    test('24 crossing agents resolve cleanly and deterministically', () {
      List<CrowdAgent3D> createRingAgents() {
        final agents = <CrowdAgent3D>[];
        const count = 24;
        const radius = 6.0;
        for (var i = 0; i < count; i++) {
          final a = (i / count) * math.pi * 2;
          final start = Vector3(math.cos(a) * radius, 0, math.sin(a) * radius);
          final goal = Vector3(-start.x, 0, -start.z);
          agents.add(
            CrowdAgent3D(
              position: start,
              radius: 0.45,
              maxSpeed: 2.5,
            )..setPath([start.clone(), goal]),
          );
        }
        return agents;
      }

      final agents1 = createRingAgents();
      final agents2 = createRingAgents();
      final crowd1 = CrowdSteering3D(agents: agents1);
      final crowd2 = CrowdSteering3D(agents: agents2);

      var minDist = double.infinity;
      for (var step = 0; step < 180; step++) {
        crowd1.update(1.0 / 60.0);
        crowd2.update(1.0 / 60.0);
        for (var i = 0; i < agents1.length; i++) {
          for (var j = i + 1; j < agents1.length; j++) {
            final d = agents1[i].position.distanceTo(agents1[j].position);
            if (d < minDist) {
              minDist = d;
            }
          }
        }
      }

      expect(minDist, greaterThan(0.55));
      for (var i = 0; i < agents1.length; i++) {
        final p1 = agents1[i].position;
        final p2 = agents2[i].position;
        expect(p1.x.isFinite && p1.y.isFinite && p1.z.isFinite, isTrue);
        expect(p1.distanceTo(p2), closeTo(0, 1e-6));
        expect(
          agents1[i].velocity.distanceTo(agents2[i].velocity),
          closeTo(0, 1e-6),
        );
      }
    });
  });

  group('FoliageSystem3D angle-addition wind & draw cache', () {
    test('static pose matches across calls, interactors localize to cells, and '
        'draw reuses cached buffers', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      final view = makeViewMatrix(
        Vector3(0, 2, 4),
        Vector3(0, 0, 0),
        Vector3(0, 1, 0),
      );
      final proj = makePerspectiveMatrix(math.pi / 2, 1.0, 0.1, 60.0);
      final context = RenderContext3D(device)..setCamera(view, proj);

      final interactor = FoliageInteractor3D(
        position: Vector3(0.0, 0.0, 0.0),
        radius: 1.6,
      );
      final foliage =
          FoliageSystem3D(
              capacity: 16,
              cellSize: 4.0,
              maxDrawDistance: 40.0,
              windStrength: 0.5,
              windFrequency: 2.0,
              interactors: [interactor],
            )
            ..addBlade(position: Vector3(0.3, 0.0, 0.2), densityRank: 0)
            ..addBlade(position: Vector3(20.0, 0.0, 20.0), densityRank: 0);

      for (var i = 0; i < 15; i++) {
        foliage.update(1.0 / 30.0);
      }

      // Near blade bent strongly by interactor; distant-cell blade untouched.
      expect(foliage.bladeBendVector(0).length, greaterThan(0.15));
      expect(foliage.bladeBendVector(1).length, equals(0.0));

      final frustum = Frustum.matrix(proj.clone()..multiply(view));
      final count1 = foliage.buildVisibleInstances(
        cameraPosition: Vector3(0, 2, 4),
        frustum: frustum,
      );
      expect(count1, 1);

      Float32List drawAndRead(int drawIdx) {
        device.begin();
        context.setCamera(view, proj);
        device.beginPass(const Size(64, 64), frontFace: context.frontFace);
        foliage.draw(context);
        context.flush();
        device.endPass().dispose();
        device.end();
        expect(foliage.lastVisibleInstanceCount, 1);
        return Float32List.fromList(backend.instancesOf(drawIdx).single);
      }

      final drawSnap1 = drawAndRead(0);
      final drawSnap2 = drawAndRead(1);
      expect(drawSnap2, drawSnap1);

      // Advancing time moves wind angle smoothly.
      foliage.update(0.25);
      final drawSnap3 = drawAndRead(2);
      expect(drawSnap3, isNot(equals(drawSnap1)));
    });
  });

  group('Narrowphase3D.testAllInto & PhysicsWorld3D parity', () {
    test(
      'zero-alloc buffer matches Narrowphase3D.testAll across all 6 pairs',
      () {
        final sphere = SphereShape3D(radius: 0.75);
        final capsule = CapsuleShape3D(radius: 0.4, height: 1.6);
        final box = BoxShape3D(halfExtents: Vector3(0.6, 0.5, 0.7));

        final rotA = Matrix4.identity()
          ..setTranslation(Vector3(0.1, 0.2, 0.0))
          ..rotateY(0.45)
          ..rotateX(0.2);
        final rotB = Matrix4.identity()
          ..setTranslation(Vector3(0.7, 0.3, 0.15))
          ..rotateZ(0.35)
          ..rotateY(-0.3);
        final farB = Matrix4.translationValues(12.0, 0.0, 0.0);

        final pairs = <(String, Shape3D, Matrix4, Shape3D, Matrix4)>[
          ('sphere-sphere overlap', sphere, rotA, sphere, rotB),
          ('sphere-sphere apart', sphere, rotA, sphere, farB),
          ('sphere-capsule overlap', sphere, rotA, capsule, rotB),
          ('capsule-sphere overlap', capsule, rotA, sphere, rotB),
          ('capsule-capsule overlap', capsule, rotA, capsule, rotB),
          ('sphere-box overlap', sphere, rotA, box, rotB),
          ('box-sphere overlap', box, rotA, sphere, rotB),
          ('capsule-box overlap', capsule, rotA, box, rotB),
          ('box-capsule overlap', box, rotA, capsule, rotB),
          ('box-box overlap', box, rotA, box, rotB),
          ('box-box apart', box, rotA, box, farB),
        ];

        final buf = MutableManifoldBuffer3D();
        for (final (label, a, ta, b, tb) in pairs) {
          final expected = Narrowphase3D.testAll(a, ta, b, tb);
          buf.clear();
          Narrowphase3D.testAllInto(a, ta, b, tb, buf);

          expect(buf.manifoldCount, expected.length, reason: label);
          for (var m = 0; m < expected.length; m++) {
            final em = expected[m];
            expect(buf.normalX(m), closeTo(em.normal.x, 1e-5), reason: label);
            expect(buf.normalY(m), closeTo(em.normal.y, 1e-5), reason: label);
            expect(buf.normalZ(m), closeTo(em.normal.z, 1e-5), reason: label);
            expect(
              buf.depth(m),
              closeTo(em.penetrationDepth, 1e-5),
              reason: label,
            );
            expect(
              buf.contactLength(m),
              em.contacts.length,
              reason: '$label contact count',
            );
            final start = buf.contactStart(m);
            for (var c = 0; c < em.contacts.length; c++) {
              final ec = em.contacts[c];
              final ci = start + c;
              expect(
                buf.pointAX(ci),
                closeTo(ec.pointA.x, 1e-5),
                reason: '$label pax[$c]',
              );
              expect(
                buf.pointAY(ci),
                closeTo(ec.pointA.y, 1e-5),
                reason: '$label pay[$c]',
              );
              expect(
                buf.pointAZ(ci),
                closeTo(ec.pointA.z, 1e-5),
                reason: '$label paz[$c]',
              );
              expect(
                buf.pointBX(ci),
                closeTo(ec.pointB.x, 1e-5),
                reason: '$label pbx[$c]',
              );
              expect(
                buf.pointBY(ci),
                closeTo(ec.pointB.y, 1e-5),
                reason: '$label pby[$c]',
              );
              expect(
                buf.pointBZ(ci),
                closeTo(ec.pointB.z, 1e-5),
                reason: '$label pbz[$c]',
              );
            }
          }
        }
      },
    );

    test(
      'PhysicsWorld3D settles sphere, box, and capsule cleanly on floor',
      () {
        final physics = PhysicsWorld3D(gravity: Vector3(0, -9.81, 0));
        final floor = RigidBody3D(
          bodyType: BodyType3D.static,
          shape: BoxShape3D(halfExtents: Vector3(20, 0.5, 20)),
          position: Vector3(0, -0.5, 0),
        );
        final ball = RigidBody3D(
          shape: SphereShape3D(radius: 0.5),
          position: Vector3(-3, 2.0, 0),
        );
        final box = RigidBody3D(
          shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
          position: Vector3(0, 2.0, 0),
        );
        final capsule = RigidBody3D(
          shape: CapsuleShape3D(radius: 0.35, height: 1.2),
          position: Vector3(3, 2.0, 0),
        );
        physics
          ..addBody(floor)
          ..addBody(ball)
          ..addBody(box)
          ..addBody(capsule);

        for (var i = 0; i < 180; i++) {
          physics.step(1.0 / 60.0);
        }

        expect(ball.position.y, closeTo(0.5, 0.05));
        expect(box.position.y, closeTo(0.5, 0.05));
        expect(capsule.position.y, closeTo(0.6, 0.1));
      },
    );
  });

  group('World3D.occlusionCuller', () {
    setUp(() => FakeGpuBackend(textureTargets: true));

    testWithGame<FlameGame3D>(
      'culls occluded main-pass objects while keeping visible objects and '
      'shadow casters',
      () {
        final culler = OcclusionCuller3D()
          ..addQuad(
            OccluderQuad3D.wall(
              bottomStart: Vector3(-8, -2, -10),
              bottomEnd: Vector3(8, -2, -10),
              height: 8.0,
            ),
          );
        final world = World3D(occlusionCuller: culler)
          ..addLight(
            Light(
              position: Vector3.zero(),
              source: DirectionalLight(
                direction: Vector3(0.2, -1.0, 0.3),
                shadows: ShadowSettings(),
              ),
            ),
          );
        final camera = CameraComponent3D(
          position: Vector3(0, 2, 0),
          target: Vector3(0, 2, -30),
          near: 0.5,
          far: 120.0,
          viewport: FixedResolutionViewport(resolution: Vector2(64, 64)),
        );
        return FlameGame3D(world: world, camera: camera);
      },
      (game) async {
        final occluded = _CountingObject3D(
          halfExtents: Vector3(1, 1, 1),
          position: Vector3(0, 1.5, -20),
        );
        final visible = _CountingObject3D(
          halfExtents: Vector3(1, 1, 1),
          position: Vector3(0, 1.5, -5),
        );
        await game.world.ensureAddAll([occluded, visible]);
        final canvas = Canvas(PictureRecorder());
        final context = game.context
          ..cameraMask = game.camera.cameraMask
          ..setCamera(game.camera.viewMatrix, game.camera.projectionMatrix);
        game.device.begin();
        game.world
          ..syncContextOptions(context)
          ..renderShadows(canvas)
          ..renderDepthNormals(canvas, 64, 64);
        game.device.beginPass(
          const Size(64, 64),
          frontFace: context.frontFace,
        );
        game.world.renderScene(canvas, overrideContext: context);
        context.flush();
        game.device.endPass();
        game.device.end();

        expect(visible.mainDraws, 1);
        expect(occluded.mainDraws, 0);
        expect(occluded.shadowDraws, greaterThan(0));
      },
    );
  });

  group('StaticMeshBatcher3D vertex colors & O(1) visibility bounds', () {
    test('toggles O(1) slot visibility bounds accurately and respects '
        'bakeVertexColor', () {
      FakeGpuBackend();
      final device = GraphicsDevice();
      final view = makeViewMatrix(
        Vector3(0, 0, 15),
        Vector3(0, 0, 0),
        Vector3(0, 1, 0),
      );
      final proj = makePerspectiveMatrix(math.pi / 2, 1.0, 0.1, 100.0);
      final context = RenderContext3D(device)..setCamera(view, proj);

      final mat = SpatialMaterial();
      final cube = CuboidMesh(size: Vector3.all(1.0), material: mat);

      final bakedBatcher = StaticMeshBatcher3D()
        ..addStaticInstance(
          mesh: cube,
          transform: Matrix4.translationValues(0, 0, 0),
          color: const Color(0xFFFF0000),
        );
      final edgeSlot = bakedBatcher.addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(10, 0, 0),
        color: const Color(0xFF00FF00),
      );
      final midSlot = bakedBatcher.addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(5, 0, 0),
        color: const Color(0xFF0000FF),
      );

      final fullAabb = bakedBatcher.computeLocalAabb()!;
      expect(fullAabb.min.x, closeTo(-0.5, 1e-4));
      expect(fullAabb.max.x, closeTo(10.5, 1e-4));

      // Hiding an interior slot leaves hull bounds intact.
      bakedBatcher.setSlotVisible(midSlot, visible: false);
      expect(bakedBatcher.computeLocalAabb()!.max.x, closeTo(10.5, 1e-4));

      // Hiding the boundary slot shrinks hull bounds cleanly.
      bakedBatcher.setSlotVisible(edgeSlot, visible: false);
      expect(bakedBatcher.computeLocalAabb()!.max.x, closeTo(0.5, 1e-4));

      // Restoring boundary slot restores hull bounds.
      bakedBatcher.setSlotVisible(edgeSlot, visible: true);
      expect(bakedBatcher.computeLocalAabb()!.max.x, closeTo(10.5, 1e-4));

      bakedBatcher.draw(context);
      expect(bakedBatcher.lastDrawnBatchCount, 1);

      final unbakedBatcher = StaticMeshBatcher3D(bakeVertexColor: false)
        ..addStaticInstance(
          mesh: cube,
          transform: Matrix4.translationValues(0, 0, 0),
          color: const Color(0xFFFF0000),
        )
        ..addStaticInstance(
          mesh: cube,
          transform: Matrix4.translationValues(2, 0, 0),
          color: const Color(0xFF00FF00),
        );
      unbakedBatcher.draw(context);
      // Distinct per-instance colors remain separate draw batches when not
      // baked into vertex colors.
      expect(unbakedBatcher.lastDrawnBatchCount, 2);
    });
  });
}
