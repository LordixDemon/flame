import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/audio.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend() implements AudioVoiceBackend3D {
  int _next = 1;
  final Map<int, SpatialAudioEmitter3D> active = {};
  final List<SpatialAudioEmitter3D> stopped = [];

  @override
  int startVoice(SpatialAudioEmitter3D emitter, AudioVoiceParams3D params) {
    final handle = _next++;
    active[handle] = emitter;
    return handle;
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

FlameGame _game() => FlameGame(world: World3D());

SpatialAudioEmitter3D _emitter(double x, {int priority = 0}) {
  return SpatialAudioEmitter3D(
    clipDuration: 10,
    autoComputeVelocity: false,
    attenuationModel: AudioAttenuationModel3D.linear,
    maxDistance: 100,
    priority: priority,
    position: Vector3(x, 0, 0),
  );
}

void main() {
  group('SpatialAudioMixer3D in a mounted world', () {
    testWithGame(
      'finds the listener and the emitters of its world and forgets an '
      'emitter removed while playing',
      _game,
      (game) async {
        final world = game.world as World3D;
        final backend = _Backend();
        final listener = SpatialAudioListener3D(autoComputeVelocity: false);
        final near = _emitter(2);
        final far = _emitter(8);
        final mixer = SpatialAudioMixer3D(backend: backend, maxRealVoices: 4);
        world.addAll([listener, near, far, mixer]);
        await game.ready();

        game.update(0.1);
        expect(mixer.realVoiceCount, 2);
        expect(mixer.voiceParamsFor(near), isNotNull);

        near.removeFromParent();
        await game.ready();
        game.update(0.1);
        game.update(0.1);
        expect(mixer.voiceParamsFor(near), isNull);
        expect(mixer.isEmitterReal(near), isFalse);
        expect(mixer.realVoiceCount, 1);
        expect(backend.stopped, contains(near));
        expect(backend.active.values, isNot(contains(near)));
      },
    );

    testWithGame(
      'unregisterEmitter keeps a world emitter out of the mix until it is '
      'registered again',
      _game,
      (game) async {
        final world = game.world as World3D;
        final backend = _Backend();
        final listener = SpatialAudioListener3D(autoComputeVelocity: false);
        final emitter = _emitter(3);
        final mixer = SpatialAudioMixer3D(backend: backend);
        world.addAll([listener, emitter, mixer]);
        await game.ready();

        game.update(0.1);
        expect(mixer.isEmitterReal(emitter), isTrue);

        mixer.unregisterEmitter(emitter);
        for (var i = 0; i < 3; i++) {
          game.update(0.1);
        }
        expect(mixer.isEmitterReal(emitter), isFalse);
        expect(mixer.voiceParamsFor(emitter), isNull);
        expect(backend.active, isEmpty);

        mixer.registerEmitter(emitter);
        game.update(0.1);
        expect(mixer.isEmitterReal(emitter), isTrue);
        expect(backend.active.values.where((e) => e == emitter), hasLength(1));
      },
    );

    testWithGame(
      'evaluates each emitter once per frame and reports it to onMixChanged',
      _game,
      (game) async {
        final world = game.world as World3D;
        var filterCalls = 0;
        var mixCalls = 0;
        final listener = SpatialAudioListener3D(autoComputeVelocity: false);
        final wall = MeshComponent(
          mesh: CuboidMesh(size: Vector3(4, 4, 0.2)),
          position: Vector3(3, 0, 0),
        );
        final emitter = SpatialAudioEmitter3D(
          autoComputeVelocity: false,
          enableOcclusion: true,
          occlusionFilter: (object) {
            filterCalls++;
            return true;
          },
          onMixChanged: (_) => mixCalls++,
          position: Vector3(6, 0, 0),
        );
        final mixer = SpatialAudioMixer3D(backend: _Backend());
        world.addAll([listener, wall, emitter, mixer]);
        await game.ready();

        game.update(0.1);
        filterCalls = 0;
        mixCalls = 0;
        for (var i = 0; i < 10; i++) {
          game.update(0.1);
        }
        // One raycast (one candidate: the wall) and one report per frame;
        // the emitter and the mixer both evaluated it before.
        expect(filterCalls, 10);
        expect(mixCalls, 10);
        expect(emitter.lastMix.occluded, isTrue);
      },
    );

    testWithGame(
      'onReverbChanged fires only while the reverb changes',
      _game,
      (game) async {
        final world = game.world as World3D;
        final changes = <ReverbPreset3D>[];
        final listener = SpatialAudioListener3D(autoComputeVelocity: false);
        final zone = AudioZone3D(preset: ReverbPreset3D.cave, radius: 4);
        final mixer = SpatialAudioMixer3D(
          backend: _Backend(),
          reverbCrossfadeSpeed: 0,
          onReverbChanged: changes.add,
        );
        world.addAll([listener, mixer]);
        await game.ready();

        for (var i = 0; i < 5; i++) {
          game.update(0.1);
        }
        expect(changes, isEmpty);

        world.add(zone);
        await game.ready();
        for (var i = 0; i < 5; i++) {
          game.update(0.1);
        }
        expect(changes, hasLength(1));
        expect(changes.single.wetMix, ReverbPreset3D.cave.wetMix);
        expect(mixer.currentReverb.name, 'cave');
      },
    );

    testWithGame(
      'audio priority ranks voices without reordering the components',
      _game,
      (game) async {
        final world = game.world as World3D;
        final listener = SpatialAudioListener3D(autoComputeVelocity: false);
        final loud = _emitter(2);
        final important = _emitter(4, priority: 10);
        final mixer = SpatialAudioMixer3D(
          backend: _Backend(),
          maxRealVoices: 1,
        );
        world.addAll([listener, loud, important, mixer]);
        await game.ready();

        expect(important.audioPriority, 10);
        expect(important.priority, 0);
        game.update(0.1);
        expect(mixer.isEmitterReal(important), isTrue);
        expect(mixer.isEmitterReal(loud), isFalse);

        important.audioPriority = 0;
        game.update(0.1);
        expect(mixer.isEmitterReal(loud), isTrue);
      },
    );
  });
}
