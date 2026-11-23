import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect, Size;

import 'package:flame_3d/audio.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/ui3d.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

class _TestVoiceBackend() implements AudioVoiceBackend3D {
  int nextHandle = 1;
  final Map<int, SpatialAudioEmitter3D> active = {};
  final List<SpatialAudioEmitter3D> stopped = [];

  @override
  int startVoice(SpatialAudioEmitter3D emitter, AudioVoiceParams3D params) {
    final h = nextHandle++;
    active[h] = emitter;
    return h;
  }

  @override
  void updateVoice(
    int voiceHandle,
    SpatialAudioEmitter3D emitter,
    AudioVoiceParams3D params,
  ) {}

  @override
  void stopVoice(int voiceHandle, SpatialAudioEmitter3D emitter) {
    active.remove(voiceHandle);
    stopped.add(emitter);
  }
}

Model _buildChainModel(int boneCount, {bool withMesh = true}) {
  final mat = SpatialMaterial();
  final nodes = <int, ModelNode>{};
  for (var i = 0; i < boneCount; i++) {
    final parent = i == 0 ? null : i - 1;
    nodes[i] = ModelNode(
      name: 'Bone$i',
      nodeIndex: i,
      parentNodeIndex: parent,
      transform: Matrix4.translationValues(0, i == 0 ? 0.0 : 1.0, 0),
      mesh: null,
      joints: const {},
    );
  }
  if (withMesh) {
    final surf = Surface.fromBuffers(
      vertices: Float32List(20 * 3),
      indices: Uint16List.fromList(const [0, 1, 2]),
      material: mat,
      jointMap: {for (var j = 0; j < boneCount; j++) j: j},
    );
    final mesh = Mesh()..addSurface(surf);
    final joints = {
      for (var j = 0; j < boneCount; j++)
        j: ModelJoint(nodeIndex: j, inverseBindMatrix: Matrix4.identity()),
    };
    nodes[boneCount] = ModelNode(
      name: 'MeshNode',
      nodeIndex: boneCount,
      parentNodeIndex: null,
      transform: Matrix4.identity(),
      mesh: mesh,
      joints: joints,
    );
  }

  ModelAnimation makeClip(String name, double yTarget) {
    return ModelAnimation(
      name: name,
      nodes: {
        for (var i = 0; i < boneCount; i++)
          i: NodeAnimation(
            channels: [
              AnimationController(
                animation: TranslationAnimationSpline.from(
                  interpolation: AnimationInterpolation.linear,
                  times: const [0.0, 1.0],
                  values: [
                    Vector3(0, i == 0 ? 0.0 : 1.0, 0),
                    Vector3(0, (i == 0 ? 0.0 : 1.0) + yTarget, 0),
                  ],
                ),
              ),
            ],
          ),
      },
    );
  }

  return Model(
    nodes: nodes,
    animations: [
      makeClip('c0', 0.0),
      makeClip('c1', 0.4),
      makeClip('c2', 0.8),
      makeClip('c3', 1.2),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 2 Wave 4 animation & IK optimizations', () {
    test('BlendSpace1D and BlendSpace2D cached weights track param edits '
        'accurately', () {
      final model = _buildChainModel(80, withMesh: false);
      final workspace = ModelPoseWorkspace.forModel(model);
      final state1D = AnimationState()
        ..playBlendSpace1D(
          BlendSpace1D(
            samples: [
              BlendSample1D(animation: model.animations[0], position: 0.0),
              BlendSample1D(animation: model.animations[1], position: 1.0),
              BlendSample1D(animation: model.animations[2], position: 2.0),
            ],
          ),
          initialValue: 0.5,
        );

      state1D.setNormalizedPhase(0.5);
      model.evaluateInto(state1D, workspace);
      final yAtHalf = workspace.nodesByIndex[79]!.combinedTransform.storage[13];

      state1D.blendParameter1D = 1.5;
      model.evaluateInto(state1D, workspace);
      final yAtOneHalf =
          workspace.nodesByIndex[79]!.combinedTransform.storage[13];
      expect(yAtOneHalf, greaterThan(yAtHalf));

      final space2D = BlendSpace2D(
        samples: [
          BlendSample2D(
            animation: model.animations[0],
            point: Vector2(-1, -1),
          ),
          BlendSample2D(
            animation: model.animations[1],
            point: Vector2(1, -1),
          ),
          BlendSample2D(
            animation: model.animations[2],
            point: Vector2(-1, 1),
          ),
          BlendSample2D(animation: model.animations[3], point: Vector2(1, 1)),
        ],
      );
      final state2D = AnimationState()
        ..playBlendSpace2D(space2D, initialValue: Vector2(-0.5, -0.5));
      state2D.setNormalizedPhase(0.5);
      model.evaluateInto(state2D, workspace);
      final y2dLow = workspace.nodesByIndex[79]!.combinedTransform.storage[13];

      state2D.blendParameter2D.setValues(0.8, 0.8);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        model.evaluateInto(state2D, workspace);
      }
      sw.stop();
      final y2dHigh = workspace.nodesByIndex[79]!.combinedTransform.storage[13];
      expect(y2dHigh, greaterThan(y2dLow));
      // ignore: avoid_print
      print('Wave4 80-bone BlendSpace2D x200: ${sw.elapsedMicroseconds} us');
    });

    test('single-pass IK, FABRIK, RootMotion, and partial Ragdoll preserve '
        'subtrees', () {
      final model = _buildChainModel(5, withMesh: false);
      final workspace = ModelPoseWorkspace.forModel(model);
      final id = Matrix4.identity();

      // 1. TwoBoneIkConstraint3D (`0 -> 1 -> 2`) propagates to leaf `3, 4`.
      model.evaluateInto(AnimationState(), workspace);
      TwoBoneIkConstraint3D(
        rootNodeName: 'Bone0',
        midNodeName: 'Bone1',
        tipNodeName: 'Bone2',
        targetWorld: Vector3(1.2, 1.2, 0.0),
        poleWorld: Vector3(0.0, 0.0, 1.0),
      ).apply(model, workspace, id, id, 0.016);
      final tipPos = workspace.nodesByIndex[2]!.combinedTransform.storage;
      final leafPos = workspace.nodesByIndex[4]!.combinedTransform.storage;
      final dxLeaf = leafPos[12] - tipPos[12];
      final dyLeaf = leafPos[13] - tipPos[13];
      final dzLeaf = leafPos[14] - tipPos[14];
      expect(
        math.sqrt(dxLeaf * dxLeaf + dyLeaf * dyLeaf + dzLeaf * dzLeaf),
        closeTo(2.0, 1e-4),
      );

      // 2. FabrikIkConstraint3D reaches target and carries non-chain tail `4`.
      model.evaluateInto(AnimationState(), workspace);
      FabrikIkConstraint3D(
        chainNodeIndices: const [0, 1, 2, 3],
        targetPosition: Vector3(2.2, 1.5, 0.0),
        maxIterations: 15,
      ).apply(model, workspace, id, id, 0.016);
      final end3 = workspace.nodesByIndex[3]!.combinedTransform.storage;
      expect(
        math.sqrt(
          (end3[12] - 2.2) * (end3[12] - 2.2) +
              (end3[13] - 1.5) * (end3[13] - 1.5) +
              end3[14] * end3[14],
        ),
        lessThan(0.05),
      );
      final end4 = workspace.nodesByIndex[4]!.combinedTransform.storage;
      expect(
        math.sqrt(
          (end4[12] - end3[12]) * (end4[12] - end3[12]) +
              (end4[13] - end3[13]) * (end4[13] - end3[13]) +
              (end4[14] - end3[14]) * (end4[14] - end3[14]),
        ),
        closeTo(1.0, 1e-4),
      );

      // 3. RootMotionExtractor3D pose lock shifts root + descendants uniformly.
      final anim = ModelAnimation(
        name: 'move',
        nodes: {
          0: NodeAnimation(
            channels: [
              AnimationController(
                animation: TranslationAnimationSpline.from(
                  interpolation: AnimationInterpolation.linear,
                  times: const [0.0, 1.0],
                  values: [Vector3.zero(), Vector3(3.0, 0.0, 0.0)],
                ),
              ),
            ],
          ),
        },
      );
      final rmModel = Model(nodes: model.nodes, animations: [anim]);
      final rmState = AnimationState()..startAnimation(anim);
      rmState.clock = 1.0;
      final extractor = RootMotionExtractor3D(rootNodeIndex: 0);
      rmModel.evaluateInto(rmState, workspace, rootMotion: extractor);
      expect(
        workspace.nodesByIndex[0]!.combinedTransform.storage[12],
        closeTo(0.0, 1e-5),
      );
      expect(
        workspace.nodesByIndex[4]!.combinedTransform.storage[12],
        closeTo(0.0, 1e-5),
      );

      // 4. Partial Ragdoll (`weight: 0.5`) propagates to non-limb leaf `4`.
      final ragModel = _buildChainModel(5, withMesh: false);
      final comp = ModelComponent(model: ragModel);
      final physics = PhysicsWorld3D();
      final ragdoll = RagdollController3D(
        modelComponent: comp,
        physicsWorld: physics,
        boneConfigs: [
          RagdollBoneConfig3D(nodeIndex: 0),
          RagdollBoneConfig3D(nodeIndex: 1),
          RagdollBoneConfig3D(nodeIndex: 2),
          RagdollBoneConfig3D(nodeIndex: 3),
        ],
      );
      ragdoll
        ..weight = 0.5
        ..activateRagdoll();
      ragdoll.bodyForBone(2)!.bodyPosition.x += 2.0;
      final ragWs = comp.evaluatePose();
      final b2X = ragWs.nodesByIndex[2]!.combinedTransform.storage[12];
      final b3X = ragWs.nodesByIndex[3]!.combinedTransform.storage[12];
      final b4X = ragWs.nodesByIndex[4]!.combinedTransform.storage[12];
      expect(b2X, closeTo(1.0, 1e-3));
      expect(b3X, closeTo(0.5, 1e-3));
      expect(b4X, closeTo(0.5, 1e-3));
    });
  });

  group('Stage 2 Wave 4 GPU instance caching, crowd & foliage', () {
    test('GraphicsDevice.bindInstances promotes unchanged buffers on frame 2 '
        'and invalidates cleanly on version bump or device loss', () async {
      final backend = FakeGpuBackend(inputs: const []);
      final device = GraphicsDevice(backend: backend);
      final mat = SpatialMaterial();
      final surf = Surface.fromBuffers(
        vertices: Float32List(20 * 3),
        indices: Uint16List.fromList(const [0, 1, 2]),
        material: mat,
      );
      final instances = Float32List(2 * VertexLayout.instanceStrideInFloats);
      instances[0] = 1;
      instances[5] = 1;
      instances[10] = 1;
      instances[15] = 1;

      void drawOnce(int version) {
        device.begin();
        device.beginPass(const Size(16, 16));
        device.bindSurface(surf);
        device.bindInstances(instances, 2, version: version);
        device.drawSurface(surf, instanceCount: 2);
        device.endPass().dispose();
        device.end();
      }

      // Frame 1: uploads to transient arena.
      drawOnce(1);
      final frame1Bytes = device.lastFrameStats.uploadedBytes;
      expect(frame1Bytes, 2 * VertexLayout.instanceStrideInFloats * 4);
      final buffersAfterF1 = backend.buffers.length;

      // Frame 2: promotes to persistent GpuBuffer.
      drawOnce(1);
      expect(device.lastFrameStats.uploadedBytes, frame1Bytes);
      expect(backend.buffers.length, buffersAfterF1 + 1);

      // Frame 3: reuses persistent GpuBuffer with zero bytes uploaded.
      drawOnce(1);
      expect(device.lastFrameStats.uploadedBytes, 0);
      expect(backend.buffers.length, buffersAfterF1 + 1);

      // Version bump drops persistent cache and re-uploads.
      drawOnce(2);
      expect(device.lastFrameStats.uploadedBytes, frame1Bytes);

      // Frame after bump promotes new persistent buffer cleanly.
      drawOnce(2);
      expect(device.lastFrameStats.uploadedBytes, frame1Bytes);
      drawOnce(2);
      expect(device.lastFrameStats.uploadedBytes, 0);

      // Device loss forces fresh upload even at same version.
      await backend.debugSimulateDeviceLoss();
      drawOnce(2);
      expect(device.lastFrameStats.uploadedBytes, frame1Bytes);
    });

    test('InstancedGroup3D & SkinnedCrowdBatch3D cache across passes', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());

      final cube = CuboidMesh(
        size: Vector3.all(1),
        material: SpatialMaterial(),
      );
      final group = InstancedGroup3D(mesh: cube)
        ..addInstance(transform: Matrix4.translationValues(1, 0, 0))
        ..addInstance(transform: Matrix4.translationValues(-1, 0, 0));

      device.begin();
      device.beginPass(const Size(32, 32));
      group.draw(context);
      context.flush();
      device.endPass().dispose();
      device.end();
      final bytesF1 = device.lastFrameStats.uploadedBytes;

      // Frames 2 & 3 with static group promote and drop instance upload to 0.
      for (var f = 0; f < 2; f++) {
        device.begin();
        device.beginPass(const Size(32, 32));
        group.draw(context);
        context.flush();
        device.endPass().dispose();
        device.end();
      }
      expect(device.lastFrameStats.uploadedBytes, lessThan(bytesF1));

      final crowdModel = _buildChainModel(4);
      final crowd = SkinnedCrowdBatch3D(model: crowdModel, initialCapacity: 8)
        ..addAgent(position: Vector3(0, 0, 0))
        ..addAgent(position: Vector3(2, 0, 0), initialClock: 0.4);
      device.begin();
      device.beginPass(const Size(32, 32));
      crowd.draw(context);
      context.flush();
      device.endPass().dispose();
      device.end();
      expect(crowd.lastSkinnedNodeDraws, 2);
      expect(crowd.lastSkinnedPoseBuckets, greaterThanOrEqualTo(1));
    });

    test(
      'FoliageSystem3D keeps shadow & main caches separate and scatters',
      () {
        final terrain = ChunkedTerrain3D.procedural(
          gridColumns: 33,
          gridRows: 33,
          worldWidth: 32,
          worldDepth: 32,
        );
        final foliage = FoliageSystem3D(
          capacity: 1024,
          maxDrawDistance: 80,
          windStrength: 0.2,
          castsShadows: true,
        );
        final placed = foliage.scatterOnTerrain(terrain, count: 512, seed: 42);
        expect(placed, 512);
        expect(foliage.bladeCount, 512);
        expect(foliage.cellCount, greaterThan(0));
        terrain.onRemove();
      },
    );
  });

  group('Stage 2 Wave 4 UI3D, terrain, decals & audio optimizations', () {
    test(
      'WidgetSurface3D, Text3DComponent & MsdfTextBatch3D in-place updates',
      () {
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device)
          ..setCamera(
            Matrix4.identity(),
            Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
          );

        final btn = SurfaceButton2D(
          bounds: const Rect.fromLTWH(10, 10, 100, 40),
          label: 'GO',
        );
        final panel = WidgetSurface3D(controls: [btn])
          ..markDirty()
          ..flushDirty()
          ..onRemove();
        expect(panel.uploadCount, 2);

        final label = Text3DComponent(text: 'HP 100');
        device.begin();
        device.beginPass(const Size(32, 32));
        label.draw(context);
        context.flush();
        device.endPass().dispose();
        device.end();

        label.position.setValues(1, 2, -3);
        device.begin();
        device.beginPass(const Size(32, 32));
        label.draw(context);
        context.flush();
        device.endPass().dispose();
        device.end();

        final batch = MsdfTextBatch3D();
        final s0 = batch.addText('HP 100\nOK', position: Vector3(0, 0, -4));
        final s1 = batch.addText('TAG', position: Vector3(2, 0, -4));
        expect(batch.glyphCount, 10);
        // Same visible glyph count triggers in-place fast path!
        batch.setText(s0, 'HP 999\nNO', color: const Color(0xFFFF0000));
        expect(batch.glyphCount, 10);
        batch.setText(s1, 'LONGER');
        expect(batch.glyphCount, 13);
        expect(batch.computeLocalAabb(), isNotNull);
      },
    );

    test('ChunkedTerrain3D color parity, zero-surface raycast & decals', () {
      const palette = TerrainBiomePalette3D();
      final out = Float32List(4);
      for (final hNorm in [0.0, 0.15, 0.45, 0.78, 0.96]) {
        for (final ny in [0.3, 0.7, 0.95]) {
          final col = palette.evaluateColor(hNorm, ny);
          palette.writeColorTo(hNorm, ny, out, 0);
          expect(out[0], closeTo(col.r, 1e-6));
          expect(out[1], closeTo(col.g, 1e-6));
          expect(out[2], closeTo(col.b, 1e-6));
          expect(out[3], closeTo(1.0, 1e-6));
        }
      }

      final terrain = ChunkedTerrain3D.procedural(
        gridColumns: 33,
        gridRows: 33,
        worldWidth: 32,
        worldDepth: 32,
      )..scale.setValues(1, 1.5, 1);
      final expectedY = terrain.sampleHeight(2.0, -2.0) * 1.5;
      final hit = terrain.raycast(
        Ray.originDirection(Vector3(2.0, 50, -2.0), Vector3(0, -1, 0)),
      );
      expect(hit, isNotNull);
      expect(hit!.worldPoint.y, closeTo(expectedY, 1e-2));
      final triHit = terrain.raycast(
        Ray.originDirection(Vector3(2.3, 50, -1.7), Vector3(0, -1, 0)),
      );
      expect(triHit, isNotNull);
      expect(
        triHit!.worldPoint.y,
        closeTo(terrain.sampleHeight(2.3, -1.7) * 1.5, 0.05),
      );

      final decals = VolumeDecalBatch3D()
        ..projectOntoTerrain([
          ProjectedDecalBox3D(
            center: Vector3(2.0, expectedY, -2.0),
            halfExtents: Vector3(3.0, 8.0, 3.0),
          ),
        ], terrain);
      expect(decals.generatedTriangleCount, greaterThan(0));
      terrain.onRemove();
    });

    test('SpatialAudioMixer3D skips occlusionQuery for inaudible emitters '
        'while advancing playbackPosition', () {
      var occCalls = 0;
      final backend = _TestVoiceBackend();
      final listener = SpatialAudioListener3D(
        position: Vector3.zero(),
        autoComputeVelocity: false,
      );
      final nearEm = SpatialAudioEmitter3D(
        clipDuration: 10.0,
        maxDistance: 20.0,
        attenuationModel: AudioAttenuationModel3D.linear,
        position: Vector3(2, 0, 0),
        autoComputeVelocity: false,
      );
      final farEm = SpatialAudioEmitter3D(
        clipDuration: 10.0,
        maxDistance: 20.0,
        attenuationModel: AudioAttenuationModel3D.linear,
        position: Vector3(50, 0, 0),
        autoComputeVelocity: false,
      );
      final mixer = SpatialAudioMixer3D(
        backend: backend,
        listener: listener,
        emitters: [nearEm, farEm],
        occlusionQuery: (a, b) {
          occCalls++;
          return 0.0;
        },
      );

      mixer.update(1.5);
      expect(occCalls, 1); // Only `nearEm` queried!
      expect(mixer.realVoiceCount, 1);
      expect(mixer.virtualVoiceCount, 1);
      expect(farEm.playbackPosition, closeTo(1.5, 1e-5));
    });
  });
}
