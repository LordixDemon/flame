import 'package:flame/audio.dart';
import 'package:flame/camera.dart';
import 'package:flame/extensions.dart';
import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioMixer hierarchy, fades, ducking & persistence', () {
    test('bus hierarchy, mute, fadeTo, one-shot expiry & settings JSON', () {
      final backend = InMemoryAudioBackend();
      final mixer = AudioMixer(backend: backend);
      mixer.bus(AudioBusId.master).volume = 0.5;
      mixer.bus(AudioBusId.sfx).volume = 0.8;

      final oneShot = mixer.playClip(
        'hit.wav',
        volume: 0.5,
        durationSeconds: 0.2,
      );
      final loopAmb = mixer.playClip(
        'rain.ogg',
        busId: AudioBusId.ambience,
        loop: true,
      );
      // Effective gain = 0.5 (master) * 0.8 (sfx) * 0.5 (source) = 0.20!
      expect(oneShot.effectiveGain, closeTo(0.20, 1e-6));
      expect(backend.activeVoices.length, 2);

      // Muting master silences all child buses on next update.
      mixer.bus(AudioBusId.master).muted = true;
      mixer.update(0.05);
      expect(oneShot.effectiveGain, 0.0);
      expect(loopAmb.effectiveGain, 0.0);
      mixer.bus(AudioBusId.master).muted = false;

      // Bus fadeTo(0 duration) snaps immediately; positive duration ramps.
      mixer.bus(AudioBusId.ambience).fadeTo(0.2, durationSeconds: 0.0);
      expect(mixer.bus(AudioBusId.ambience).volume, closeTo(0.2, 1e-6));
      mixer.bus(AudioBusId.ambience).fadeTo(1.0, durationSeconds: 0.4);
      mixer.update(0.2); // reaches midpoint AND expires 0.2s oneShot!
      expect(oneShot.isStopped, isTrue);
      expect(loopAmb.isStopped, isFalse);
      expect(mixer.bus(AudioBusId.ambience).volume, closeTo(0.6, 1e-5));

      // JSON settings export / import roundtrip.
      final saved = mixer.toSettingsJson();
      final restored = AudioMixer()..applySettingsJson(saved);
      expect(restored.bus(AudioBusId.sfx).volume, closeTo(0.8, 1e-6));

      mixer.stopAll(busId: AudioBusId.ambience);
      expect(mixer.activeVoices, isEmpty);
    });

    test('DuckingRule attack/hold/release & muted trigger bus guard', () {
      final mixer = AudioMixer();
      final bgm = mixer.playClip(
        'theme.ogg',
        busId: AudioBusId.music,
        loop: true,
      );
      expect(bgm.effectiveGain, closeTo(1.0, 1e-6));

      // Muted voice bus MUST NOT duck music!
      mixer.bus(AudioBusId.voice).muted = true;
      final mutedLine = mixer.playClip(
        'line.ogg',
        busId: AudioBusId.voice,
        durationSeconds: 0.5,
      );
      mixer.update(0.1);
      expect(bgm.effectiveGain, closeTo(1.0, 1e-6));
      mixer.stopVoice(mutedLine);

      // Unmuting voice bus ducks music down to 0.32, holds, and releases back
      // to 1.0 after voice ends!
      mixer.bus(AudioBusId.voice).muted = false;
      mixer.playClip(
        'announcer.ogg',
        busId: AudioBusId.voice,
        durationSeconds: 0.15,
      );
      mixer.update(0.10);
      expect(bgm.effectiveGain, closeTo(0.32, 1e-3));

      // Advance past voice duration + hold (0.15s) + release (0.35s).
      for (var i = 0; i < 12; i++) {
        mixer.update(0.06);
      }
      expect(bgm.effectiveGain, closeTo(1.0, 1e-3));
    });
  });

  group('AdaptiveMusicController, SoundCue & SpatialAudioListener2D', () {
    test(
      'AdaptiveMusicController crossfades tracks & smooths vertical stems',
      () {
        final mixer = AudioMixer();
        final music = AdaptiveMusicController(mixer: mixer, smoothingRate: 20.0)
          ..playTrack('explore.ogg', crossfadeSeconds: 0.4);
        expect(music.activeTrackId, 'explore.ogg');
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 1);

        // Crossfade to battle.ogg spawns 2nd track voice, then retires 1st at
        // completion!
        music.playTrack('battle.ogg', crossfadeSeconds: 0.4);
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 2);
        music.update(0.2);
        mixer.update(0.2);
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 2);
        music.update(0.25);
        mixer.update(0.25);
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 1);
        expect(mixer.activeVoices.single.assetId, 'battle.ogg');

        // Vertical intensity stems ramp up as targetIntensity -> 1.0.
        music.startLayeredStems(<MusicStemLayer>[
          MusicStemLayer(
            assetId: 'drums.ogg',
            minIntensity: 0.3,
            fullIntensity: 0.9,
          ),
        ]);
        music.targetIntensity = 1.0;
        for (var i = 0; i < 20; i++) {
          music.update(0.05);
        }
        final drumVoice = mixer.activeVoices.firstWhere(
          (v) => v.assetId == 'drums.ogg',
        );
        expect(drumVoice.sourceVolume, closeTo(1.0, 0.02));
        music.stopLayeredStems();
        expect(
          mixer.activeVoices.any((v) => v.assetId == 'drums.ogg'),
          isFalse,
        );
      },
    );

    test(
      'SoundCue anti-repeat, voice-stealing policies & SpatialAudioListener2D',
      () {
        final mixer = AudioMixer();
        final rng = SeededRng(777);
        final stepCue = SoundCue(
          id: 'footstep',
          cooldownSeconds: 0.0,
          maxConcurrentVoices: 100,
          clips: <SoundClipEntry>[
            SoundClipEntry(assetId: 'step_1.wav'),
            SoundClipEntry(assetId: 'step_2.wav'),
            SoundClipEntry(assetId: 'step_3.wav'),
          ],
        );

        // Across 60 consecutive plays, avoidImmediateRepeat guarantees 0
        // back-to-back identical variations!
        String? prevAsset;
        for (var i = 0; i < 60; i++) {
          final h = mixer.playCue(stepCue, rng: rng)!;
          expect(h.assetId, isNot(prevAsset));
          prevAsset = h.assetId;
        }
        mixer.stopAll();

        // VoiceStealPolicy: rejectNewest vs stealQuietest.
        final rejectCue = SoundCue(
          id: 'coin_reject',
          cooldownSeconds: 0.0,
          maxConcurrentVoices: 2,
          stealPolicy: VoiceStealPolicy.rejectNewest,
          volumeVariance: 0.0,
          clips: <SoundClipEntry>[SoundClipEntry(assetId: 'c.wav')],
        );
        expect(mixer.playCue(rejectCue, rng: rng), isNotNull);
        expect(mixer.playCue(rejectCue, rng: rng), isNotNull);
        expect(mixer.playCue(rejectCue, rng: rng), isNull);
        mixer.stopAll();

        final stealQuietCue = SoundCue(
          id: 'explosion',
          cooldownSeconds: 0.0,
          maxConcurrentVoices: 2,
          stealPolicy: VoiceStealPolicy.stealQuietest,
          volumeVariance: 0.0,
          clips: <SoundClipEntry>[SoundClipEntry(assetId: 'boom.wav')],
        );
        final loud = mixer.playCue(
          stealQuietCue,
          rng: rng,
        )!;
        final quiet = mixer.playCue(
          stealQuietCue,
          volumeMultiplier: 0.2,
          rng: rng,
        )!;
        final newest = mixer.playCue(
          stealQuietCue,
          volumeMultiplier: 0.8,
          rng: rng,
        )!;
        expect(quiet.isStopped, isTrue);
        expect(loud.isStopped, isFalse);
        expect(newest.isStopped, isFalse);

        // SpatialAudioListener2D camera sync, rolloff curves & earshot culling.
        final cam = CameraComponent()..viewfinder.position = Vector2(100, 50);
        final listener = SpatialAudioListener2D(
          minDistance: 50,
          maxDistance: 450,
          stereoSpreadDistance: 200,
          maxPan: 0.8,
        )..syncFromCamera(cam);
        expect(listener.listenerX, 100);
        expect(listener.listenerY, 50);

        for (final mode in SpatialRolloffMode.values) {
          listener.rolloff = mode;
          final (nearGain, nearPan) = listener.evaluate(100, 50);
          final (midGain, rightPan) = listener.evaluate(300, 50);
          final (farGain, _) = listener.evaluate(600, 50);
          expect(nearGain, 1.0);
          expect(nearPan, 0.0);
          expect(midGain, inExclusiveRange(0.0, 1.0));
          expect(rightPan, closeTo(0.8, 1e-6));
          expect(farGain, 0.0);
        }

        // Out-of-earshot playCueAt skips mixer allocation entirely.
        expect(
          listener.playCueAt(
            mixer,
            stealQuietCue,
            worldX: 2000,
            worldY: 2000,
            rng: rng,
          ),
          isNull,
        );
      },
    );
  });
}
