import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

Mesh _unitTriMesh() {
  final material = UnlitMaterial();
  final stride = VertexLayout.standard.strideInFloats;
  final verts = Float32List(3 * stride);
  void put(int i, double x, double y, double z) {
    final o = i * stride;
    verts
      ..[o] = x
      ..[o + 1] = y
      ..[o + 2] = z
      ..[o + 8] = 1.0
      ..[o + 10] = 1.0;
  }

  put(0, -1, 0, -1);
  put(1, 0, 0, 1);
  put(2, 1, 0, -1);
  return Mesh()..addSurface(
    Surface.fromBuffers(
      vertices: verts,
      indices: Uint16List.fromList(const [0, 1, 2]),
      material: material,
    ),
  );
}

ModelAnimation _moveClip(String name, double startX, double endX) {
  return ModelAnimation(
    name: name,
    nodes: {
      0: NodeAnimation(
        channels: [
          AnimationController(
            animation: TranslationAnimationSpline.from(
              interpolation: AnimationInterpolation.linear,
              times: [0.0, 1.0],
              values: [Vector3(startX, 0, 0), Vector3(endX, 0, 0)],
            ),
          ),
        ],
      ),
    },
  );
}

void main() {
  group('Wave 5.1 world_scale and model decompositions', () {
    test('AnimationState per-instance scratch & pool isolation', () {
      final clipA = _moveClip('A', 0.0, 4.0);
      final clipB = _moveClip('B', 100.0, 200.0);

      final stateA = AnimationState()
        ..startAnimation(clipA)
        ..crossFadeTo(clipB, duration: 0.5)
        ..crossFadeTo(clipA, duration: 0.5);
      final stateB = AnimationState()
        ..startAnimation(clipB)
        ..crossFadeTo(clipA, duration: 0.5);

      stateA.layers.add(AnimationLayer3D(nodeIndices: {0}, weight: 0.5));
      stateA.layers.first.state.startAnimation(clipB);

      stateA.update(0.2);
      stateB.update(0.2);

      final outA = Matrix4.identity();
      final outB = Matrix4.identity();
      stateA.writeNodeTransform(
        0,
        Vector3.zero(),
        Quaternion.identity(),
        Vector3.all(1.0),
        Matrix4.identity(),
        outA,
      );
      stateB.writeNodeTransform(
        0,
        Vector3.zero(),
        Quaternion.identity(),
        Vector3.all(1.0),
        Matrix4.identity(),
        outB,
      );

      expect(outA.storage[12], isNot(closeTo(outB.storage[12], 0.5)));
      expect(stateA.isCrossFading, isTrue);
      expect(stateB.isCrossFading, isTrue);
    });

    test(
      'ChunkedTerrain3D, FoliageSystem3D, LightClusterGrid3D, Batcher & Decals',
      () {
        final heights = Float32List(9 * 9);
        for (var i = 0; i < heights.length; i++) {
          heights[i] = 1.5;
        }
        final terrain = ChunkedTerrain3D(
          heights: heights,
          gridColumns: 9,
          gridRows: 9,
          worldWidth: 16.0,
          worldDepth: 16.0,
        );
        expect(terrain.sampleHeight(0.0, 0.0), closeTo(1.5, 1e-4));
        expect(terrain.sampleNormal(0.0, 0.0).y, closeTo(1.0, 1e-4));
        expect(
          terrain.selectVisibleChunks(cameraPosition: Vector3(0, 6, 6)),
          isNotEmpty,
        );

        final hit = terrain.raycast(
          Ray.originDirection(Vector3(0, 10, 0), Vector3(0, -1, 0)),
        );
        expect(hit, isNotNull);
        expect(hit!.worldPoint.y, closeTo(1.5, 1e-4));

        final foliage = FoliageSystem3D(capacity: 64)
          ..scatterOnTerrain(terrain, count: 16)
          ..update(1.0 / 60.0);
        final visibleCount = foliage.buildVisibleInstances(
          cameraPosition: Vector3(0, 4, 8),
        );
        expect(visibleCount, greaterThan(0));

        final grid =
            LightClusterGrid3D(
              clustersX: 4,
              clustersY: 4,
              clustersZ: 4,
            )..addLight(
              ClusterLightEntry3D.point(
                position: Vector3(0, 0, -5),
                range: 8.0,
                intensity: 2.0,
              ),
            );
        final view = Matrix4.identity();
        final proj = Matrix4.identity()..setAsPerspective(60, 1, 0.5, 50);
        grid.assignLights(view, proj, near: 0.5, far: 50.0);
        final sel = grid.gatherTopLightsForAabb(
          Aabb3.minMax(Vector3(-1, -1, -6), Vector3(1, 1, -4)),
          view,
        );
        expect(sel.pointLightIndices, isNotEmpty);

        final batcher = StaticMeshBatcher3D();
        final slotId = batcher.addStaticInstance(
          mesh: _unitTriMesh(),
          transform: Matrix4.identity(),
        );
        batcher.bakeDirtyChunks();
        expect(batcher.fullBakeCount, 1);
        batcher.setSlotVisible(slotId, visible: false);
        expect(batcher.isSlotVisible(slotId), isFalse);

        final decals = VolumeDecalBatch3D()
          ..projectOntoTerrain(
            [
              ProjectedDecalBox3D(
                center: Vector3(0, 1.5, 0),
                halfExtents: Vector3(2.0, 2.0, 2.0),
              ),
            ],
            terrain,
          );
        expect(decals.computeLocalAabb(), isNotNull);
      },
    );

    test(
      'SkinnedCrowdBatch3D, BoneModifier3D, StateMachine, and ModelComponent',
      () {
        final clipIdle = _moveClip('idle', 0.0, 0.5);
        final clipRun = _moveClip('run', 1.0, 3.0);
        final mesh = _unitTriMesh();

        final model = Model(
          nodes: {
            0: ModelNode(
              name: 'root',
              nodeIndex: 0,
              parentNodeIndex: null,
              transform: Matrix4.identity(),
              mesh: mesh,
              joints: const {},
            ),
            1: ModelNode(
              name: 'mid',
              nodeIndex: 1,
              parentNodeIndex: 0,
              transform: Matrix4.translationValues(0, 1, 0),
              mesh: null,
              joints: const {},
            ),
            2: ModelNode(
              name: 'tip',
              nodeIndex: 2,
              parentNodeIndex: 1,
              transform: Matrix4.translationValues(0, 1, 0),
              mesh: null,
              joints: const {},
            ),
          },
          animations: [clipIdle, clipRun],
        );

        final crowd = SkinnedCrowdBatch3D(model: model, bakedFps: 15.0)
          ..addAgent(clipName: 'run');
        crowd.update(0.2);
        expect(crowd.agentPose(0), isNotEmpty);

        final sm = AnimationStateMachine3D(
          initialState: 'idle',
          states: [
            ClipAnimState3D(name: 'idle', animation: clipIdle),
            ClipAnimState3D(name: 'run', animation: clipRun),
          ],
          transitions: [
            AnimTransition3D(
              fromState: 'idle',
              toState: 'run',
              conditions: const [
                AnimCondition3D.greater('speed', 0.5),
              ],
            ),
          ],
        );

        final comp = ModelComponent(model: model, stateMachine: sm)
          ..boneModifiers.addAll([
            LookAtConstraint3D(
              nodeName: 'mid',
              targetWorld: Vector3(1, 1, 2),
            ),
            TwoBoneIkConstraint3D(
              rootNodeName: 'root',
              midNodeName: 'mid',
              tipNodeName: 'tip',
              targetWorld: Vector3(0.5, 1.5, 0.2),
            ),
          ]);
        comp.addOverlayLayer(boneNames: {'mid'});

        sm.setFloat('speed', 1.0);
        comp.update(0.1);
        expect(sm.currentStateName, 'run');

        final hit = comp.raycast(
          Ray.originDirection(Vector3(0, 5, 0), Vector3(0, -1, 0)),
        );
        expect(hit, isNotNull);
      },
    );
  });
}
