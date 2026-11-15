import 'package:flame/audio.dart';
import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioMixer, DuckingRule, AdaptiveMusic, SoundCue & SpatialAudio', () {
    test(
      'AudioMixer routes hierarchical buses, ducks music under voice, and '
      'persists JSON settings',
      () {
        final backend = InMemoryAudioBackend();
        final mixer = AudioMixer(backend: backend);

        mixer.bus(AudioBusId.master).volume = 0.8;
        mixer.bus(AudioBusId.music).volume = 0.5;
        final bgm = mixer.playClip(
          'bgm_theme.ogg',
          busId: AudioBusId.music,
          loop: true,
        );
        expect(bgm.effectiveGain, closeTo(0.4, 1e-4));

        // Playing announcer voice triggers default sidechain ducking on music!
        final voice = mixer.playClip(
          'announcer_double.ogg',
          busId: AudioBusId.voice,
          durationSeconds: 0.2,
        );
        mixer.update(0.10);
        expect(mixer.bus(AudioBusId.music).duckMultiplier, closeTo(0.32, 1e-3));
        expect(bgm.effectiveGain, closeTo(0.4 * 0.32, 1e-3));

        // Once voice finishes and hold + release elapse, music recovers to 1.0!
        mixer.update(0.15); // voice expires at t=0.20
        expect(voice.isStopped, isTrue);
        mixer.update(0.60);
        expect(mixer.bus(AudioBusId.music).duckMultiplier, closeTo(1.0, 1e-3));
        expect(bgm.effectiveGain, closeTo(0.4, 1e-3));

        // JSON persistence roundtrip.
        mixer.bus(AudioBusId.sfx).muted = true;
        final json = mixer.toSettingsJson();
        final restored = AudioMixer()..applySettingsJson(json);
        expect(restored.bus(AudioBusId.master).volume, closeTo(0.8, 1e-4));
        expect(restored.bus(AudioBusId.sfx).muted, isTrue);
      },
    );

    test(
      'AdaptiveMusicController crossfades tracks & blends vertical intensity '
      'stems',
      () {
        final backend = InMemoryAudioBackend();
        final mixer = AudioMixer(
          backend: backend,
          installDefaultVoiceDucking: false,
        );
        final music = AdaptiveMusicController(mixer: mixer, smoothingRate: 20.0)
          ..playTrack('calm.ogg', crossfadeSeconds: 0.5);
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 1);

        // Crossfade to action track: 2 voices during crossfade -> 1 after!
        music.playTrack('action.ogg', crossfadeSeconds: 0.5);
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 2);
        music.update(0.6);
        mixer.update(0.6);
        expect(mixer.activeVoiceCount(busId: AudioBusId.music), 1);
        expect(music.activeTrackId, 'action.ogg');

        // Vertical stems react to targetIntensity.
        mixer.stopAll();
        music.startLayeredStems(<MusicStemLayer>[
          MusicStemLayer(assetId: 'base_pad.ogg'),
          MusicStemLayer(
            assetId: 'boss_drums.ogg',
            minIntensity: 0.5,
          ),
        ]);
        music.targetIntensity = 0.0;
        music.update(0.5);
        mixer.update(0.016);
        final voicesLow = mixer.activeVoices;
        expect(voicesLow[0].effectiveGain, closeTo(1.0, 1e-2));
        expect(voicesLow[1].effectiveGain, closeTo(0.0, 1e-2));

        music.targetIntensity = 1.0;
        for (var i = 0; i < 20; i++) {
          music.update(0.05);
        }
        mixer.update(0.016);
        expect(voicesLow[1].effectiveGain, closeTo(1.0, 1e-2));
      },
    );

    test(
      'SoundCue enforces cooldown & voice stealing, and SpatialAudioListener2D '
      'computes stereo pan & distance rolloff',
      () {
        final mixer = AudioMixer(installDefaultVoiceDucking: false);
        final rng = SeededRng(12345);
        final cue = SoundCue(
          id: 'coin_pickup',
          clips: <SoundClipEntry>[
            SoundClipEntry(assetId: 'coin_a.wav', durationSeconds: 2.0),
            SoundClipEntry(assetId: 'coin_b.wav', durationSeconds: 2.0),
          ],
          maxConcurrentVoices: 2,
          cooldownSeconds: 0.05,
        );

        final first = mixer.playCue(cue, rng: rng);
        expect(first, isNotNull);
        // Immediate duplicate within 50ms cooldown is suppressed!
        expect(mixer.playCue(cue, rng: rng), isNull);

        mixer.update(0.06);
        final second = mixer.playCue(cue, rng: rng);
        expect(second, isNotNull);
        expect(mixer.activeVoiceCount(cueId: 'coin_pickup'), 2);

        // Third concurrent request steals the oldest (`first`)!
        mixer.update(0.06);
        final third = mixer.playCue(cue, rng: rng);
        expect(third, isNotNull);
        expect(first!.isStopped, isTrue);
        expect(mixer.activeVoiceCount(cueId: 'coin_pickup'), 2);

        // Spatial 2D evaluation: right of listener -> positive pan; beyond
        // maxDistance -> silent (null voice).
        final listener = SpatialAudioListener2D(
          minDistance: 50,
          maxDistance: 500,
          stereoSpreadDistance: 200,
          maxPan: 0.8,
        );
        final (nearGain, rightPan) = listener.evaluate(200, 0);
        expect(nearGain, inInclusiveRange(0.1, 0.95));
        expect(rightPan, closeTo(0.8, 1e-4));

        mixer.update(0.1);
        expect(
          listener.playCueAt(mixer, cue, worldX: 900, worldY: 0, rng: rng),
          isNull,
        );
      },
    );
  });
}
