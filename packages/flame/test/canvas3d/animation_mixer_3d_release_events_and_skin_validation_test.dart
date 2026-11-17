import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

final double _s45 = math.sin(math.pi / 4);
final double _c45 = math.cos(math.pi / 4);

SkinnedMeshWorkspace3D _twoBoneSkin() {
  final mesh = Mesh3D.box();
  return SkinnedMeshWorkspace3D(
    baseMesh: mesh,
    bones: <Bone3D>[
      Bone3D(name: 'root'),
      Bone3D(name: 'arm', parentIndex: 0, bindLocalZ: 1),
    ],
    boneIndices0: Uint16List(mesh.vertexCount),
  );
}

/// Rotates the arm (bone / node index 1) by 90 degrees about Z and holds it.
AnimationClip3D _armClip() => AnimationClip3D(
  name: 'wave',
  duration: 1,
  tracks: <TransformTrack3D>[
    TransformTrack3D(
      targetIndex: 1,
      targetName: 'arm',
      times: Float32List.fromList(<double>[0, 1]),
      rotations: Float32List.fromList(<double>[
        0, 0, _s45, _c45, //
        0, 0, _s45, _c45, //
      ]),
      translations: Float32List.fromList(<double>[0, 0, 2, 0, 0, 2]),
    ),
  ],
  morphTracks: <MorphWeightTrack3D>[
    MorphWeightTrack3D(
      targetIndex: 0,
      times: Float32List.fromList(<double>[0, 1]),
      weights: Float32List.fromList(<double>[0.8, 0.8]),
    ),
  ],
);

/// Only moves the root (bone / node index 0); nothing for the arm.
AnimationClip3D _rootClip() => AnimationClip3D(
  name: 'bob',
  duration: 1,
  tracks: <TransformTrack3D>[
    TransformTrack3D(
      targetIndex: 0,
      targetName: 'root',
      times: Float32List.fromList(<double>[0, 1]),
      translations: Float32List.fromList(<double>[0, 0, 0, 0, 0, 0.5]),
    ),
  ],
);

void main() {
  group('AnimationMixer3D releases what the current clip does not animate', () {
    test('play(B) after A: a bone B does not animate returns to its bind '
        'pose', () {
      final skin = _twoBoneSkin();
      final mixer = AnimationMixer3D(skinnedWorkspace: skin)
        ..play(_armClip())
        ..update(0.5);
      expect(skin.getBoneLocalPose(1).qz, closeTo(_s45, 1e-4));
      expect(skin.getBoneLocalPose(1).dz, closeTo(2.0, 1e-4));

      mixer
        ..play(_rootClip())
        ..update(0.1);
      final arm = skin.getBoneLocalPose(1);
      expect(arm.qz, closeTo(0.0, 1e-6));
      expect(arm.qw, closeTo(1.0, 1e-6));
      expect(arm.dz, closeTo(0.0, 1e-6));
    });

    test('crossFadeTo(B): the bone blends to its bind pose and ends exactly '
        'there, whatever the frame time', () {
      for (final duration in <double>[0.25, 0.26, 0.4]) {
        final skin = _twoBoneSkin();
        final mixer = AnimationMixer3D(skinnedWorkspace: skin)
          ..play(_armClip())
          ..update(0.5)
          ..crossFadeTo(_rootClip(), duration: duration);

        // Half way through the fade the arm is half way home.
        mixer.update(duration / 2);
        expect(
          skin.getBoneLocalPose(1).qz,
          inExclusiveRange(0.2, 0.6),
          reason: 'duration $duration',
        );

        for (var i = 0; i < 60; i++) {
          mixer.update(1 / 60);
        }
        expect(mixer.isCrossFading, isFalse);
        final arm = skin.getBoneLocalPose(1);
        expect(arm.qz, closeTo(0.0, 1e-6), reason: 'duration $duration');
        expect(arm.dz, closeTo(0.0, 1e-6), reason: 'duration $duration');
      }
    });

    test('a bone no clip ever animated keeps the pose given by hand', () {
      final skin = _twoBoneSkin()..setBonePose(1, qz: _s45, qw: _c45);
      final mixer = AnimationMixer3D(skinnedWorkspace: skin)..play(_rootClip());
      for (var i = 0; i < 30; i++) {
        mixer.update(1 / 60);
      }
      mixer.crossFadeTo(_rootClip(), duration: 0.1);
      for (var i = 0; i < 30; i++) {
        mixer.update(1 / 60);
      }
      expect(skin.getBoneLocalPose(1).qz, closeTo(_s45, 1e-6));
    });

    test('removing a layer clip releases the bones only it posed', () {
      final skin = _twoBoneSkin();
      final mixer = AnimationMixer3D(skinnedWorkspace: skin)
        ..setLayerClip(_armClip(), boneMask: <int>{1})
        ..update(0.2);
      expect(skin.getBoneLocalPose(1).qz, closeTo(_s45, 1e-4));

      mixer.setLayerClip(null);
      expect(skin.getBoneLocalPose(1).qz, closeTo(0.0, 1e-6));
    });

    test('nodes: a channel the new clip does not animate returns to the '
        'transform the node had before the mixer drove it', () {
      final root = Node3D(name: 'root');
      final arm = Node3D(name: 'arm', localZ: 0.75, localYawRad: 0.3);
      root.addChild(arm);
      final mixer = AnimationMixer3D(rootNode: root)
        ..play(_armClip())
        ..update(0.5);
      expect(arm.localZ, closeTo(2.0, 1e-6));
      expect(arm.hasLocalQuaternion, isTrue);

      // Cross-fade: half way the translation is half way back to 0.75.
      mixer
        ..crossFadeTo(_rootClip(), duration: 0.4)
        ..update(0.2);
      expect(arm.localZ, closeTo((2.0 + 0.75) / 2, 1e-3));
      for (var i = 0; i < 60; i++) {
        mixer.update(1 / 60);
      }
      expect(arm.localZ, closeTo(0.75, 1e-6));
      // Orientation is handed back to the node's own Euler angles.
      expect(arm.hasLocalQuaternion, isFalse);
      expect(arm.localYawRad, 0.3);

      // An immediate switch releases at once.
      mixer
        ..play(_armClip())
        ..update(0.1);
      expect(arm.localZ, closeTo(2.0, 1e-6));
      mixer.play(_rootClip());
      expect(arm.localZ, closeTo(0.75, 1e-6));
      expect(arm.hasLocalQuaternion, isFalse);
    });

    test('morph weights: a target the new clip does not animate returns to '
        'the weight it had before', () {
      final mesh = Mesh3D.box();
      final morph = MorphMeshWorkspace3D(
        baseMesh: mesh,
        targets: <MorphTarget3D>[
          MorphTarget3D(
            name: 'puff',
            positionDeltas: Float32List(mesh.positions.length),
          ),
        ],
      )..setWeight(0, 0.1);
      final mixer = AnimationMixer3D(morphWorkspace: morph)
        ..play(_armClip())
        ..update(0.5);
      expect(morph.weightAt(0), closeTo(0.8, 1e-6));

      mixer
        ..crossFadeTo(_rootClip(), duration: 0.4)
        ..update(0.2);
      expect(morph.weightAt(0), closeTo(0.45, 1e-3));
      for (var i = 0; i < 60; i++) {
        mixer.update(1 / 60);
      }
      expect(morph.weightAt(0), closeTo(0.1, 1e-6));
    });
  });

  group('AnimationMixer3D events', () {
    AnimationClip3D clip({required bool looping}) => AnimationClip3D(
      name: 'swing',
      duration: 1,
      looping: looping,
      events: const <AnimationEvent3D>[
        AnimationEvent3D(time: 0, name: 'start'),
        AnimationEvent3D(time: 0.5, name: 'hit'),
      ],
    );

    test('an event at time 0 of a non-looping clip fires once', () {
      final fired = <String>[];
      final mixer = AnimationMixer3D(onEvent: (e) => fired.add(e.name))
        ..play(clip(looping: false));
      for (var i = 0; i < 120; i++) {
        mixer.update(1 / 60);
      }
      expect(fired, <String>['start', 'hit']);
    });

    test('an event at time 0 of a looping clip fires once per loop, the '
        'first loop included', () {
      final fired = <String>[];
      final mixer = AnimationMixer3D(onEvent: (e) => fired.add(e.name))
        ..play(clip(looping: true));
      // 2.75 loops in steps that do not divide the duration.
      for (var i = 0; i < 110; i++) {
        mixer.update(0.025);
      }
      expect(fired, <String>[
        'start',
        'hit',
        'start',
        'hit',
        'start',
        'hit',
      ]);
    });

    test('crossFadeTo starts the new clip, so its time-0 event fires', () {
      final fired = <String>[];
      final mixer = AnimationMixer3D(onEvent: (e) => fired.add(e.name))
        ..play(_rootClip())
        ..update(0.3)
        ..crossFadeTo(clip(looping: false), duration: 0.2)
        ..update(0.1);
      expect(fired, <String>['start']);
      mixer.update(0.5);
      expect(fired, <String>['start', 'hit']);
    });
  });

  group('AnimationClip3D DA3D codec', () {
    test('a name-only track (targetIndex -1) survives the round trip', () {
      final source = AnimationClip3D(
        name: 'named',
        duration: 2,
        looping: false,
        tracks: <TransformTrack3D>[
          TransformTrack3D(
            targetIndex: -1,
            targetName: 'arm',
            times: Float32List.fromList(<double>[0, 2]),
            scales: Float32List.fromList(<double>[1, 1, 1, 2, 2, 2]),
          ),
        ],
      );
      final decoded = AnimationClip3D.fromBytes(source.toBytes());
      expect(decoded.tracks.single.targetIndex, -1);
      expect(decoded.tracks.single.targetName, 'arm');
      expect(decoded.looping, isFalse);
      expect(decoded.tracks.single.sample(1).sx, closeTo(1.5, 1e-6));
    });

    test('a truncated or foreign buffer throws FormatException', () {
      final bytes = _armClip().toBytes();
      expect(
        () => AnimationClip3D.fromBytes(
          Uint8List.sublistView(bytes, 0, bytes.length - 5),
        ),
        throwsFormatException,
      );
      expect(
        () => AnimationClip3D.fromBytes(Uint8List.sublistView(bytes, 0, 6)),
        throwsFormatException,
      );
      expect(
        () => AnimationClip3D.fromBytes(Uint8List(64)),
        throwsFormatException,
      );
    });
  });

  group('SkinnedMeshWorkspace3D bone indices', () {
    test('a weighted influence naming a missing bone is rejected up front', () {
      final mesh = Mesh3D.box();
      final bad = Uint16List(mesh.vertexCount)..[3] = 2;
      expect(
        () => SkinnedMeshWorkspace3D(
          baseMesh: mesh,
          bones: <Bone3D>[Bone3D(name: 'root')],
          boneIndices0: bad,
        ),
        throwsRangeError,
      );
    });

    test('an out-of-range index on a zero-weight influence is accepted', () {
      final mesh = Mesh3D.box();
      final n = mesh.vertexCount;
      final skin = SkinnedMeshWorkspace3D(
        baseMesh: mesh,
        bones: <Bone3D>[Bone3D(name: 'root')],
        boneIndices0: Uint16List(n),
        boneIndices1: Uint16List(n)..fillRange(0, n, 9),
        boneWeights0: Float32List(n)..fillRange(0, n, 1.0),
        boneWeights1: Float32List(n),
      );
      expect(skin.evaluateIfDirty(), isTrue);
      expect(skin.skinnedPositions, mesh.positions);
    });
  });
}
