import 'package:flame/audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioMixer one-shot lifetime', () {
    test('a voice lives for durationSeconds / pitch', () {
      final backend = InMemoryAudioBackend();
      final mixer = AudioMixer(backend: backend);
      final slow = mixer.playClip('roar', pitch: 0.5);
      final normal = mixer.playClip('step');
      final fast = mixer.playClip('blip', pitch: 2.0);

      // 0.6 s: only the double-speed clip (0.5 s of playback) is through.
      for (var i = 0; i < 6; i++) {
        mixer.update(0.1);
      }
      expect(fast.isStopped, isTrue);
      expect(normal.isStopped, isFalse);
      expect(slow.isStopped, isFalse);

      // 1.2 s: the normal clip is through, the half-speed one (2.0 s of
      // playback) is 60% in and still held by the backend.
      for (var i = 0; i < 6; i++) {
        mixer.update(0.1);
      }
      expect(normal.isStopped, isTrue);
      expect(slow.isStopped, isFalse);
      expect(slow.playheadSeconds, closeTo(0.6, 1e-9));
      expect(backend.activeVoices.containsKey(slow.voiceId), isTrue);

      // 2.1 s: now it has played through.
      for (var i = 0; i < 9; i++) {
        mixer.update(0.1);
      }
      expect(slow.isStopped, isTrue);
      expect(backend.activeVoices, isEmpty);
    });

    test('a pitch change in mid-flight moves the end accordingly', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final voice = mixer.playClip('whoosh');
      mixer.update(0.5);
      voice.pitch = 0.5;
      mixer.update(0.5);
      // Half the clip at full speed, a quarter at half speed.
      expect(voice.playheadSeconds, closeTo(0.75, 1e-9));
      expect(voice.isStopped, isFalse);
      mixer.update(0.5);
      expect(voice.isStopped, isTrue);
    });

    test('a looping voice is never retired by its duration', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final loop = mixer.playClip('wind', loop: true, durationSeconds: 0.2);
      for (var i = 0; i < 50; i++) {
        mixer.update(0.1);
      }
      expect(loop.isStopped, isFalse);
    });
  });

  group('AdaptiveMusicController volumes', () {
    AdaptiveMusicController controllerWith(AudioMixer mixer) =>
        AdaptiveMusicController(mixer: mixer, smoothingRate: 50.0);

    void settle(AdaptiveMusicController music) {
      for (var i = 0; i < 200; i++) {
        music.update(0.05);
      }
    }

    test('a stem never gets quieter when intensity rises', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final music = controllerWith(mixer)
        ..startLayeredStems(<MusicStemLayer>[
          MusicStemLayer(assetId: 'pad'),
          MusicStemLayer(
            assetId: 'drums',
            minIntensity: 0.25,
            fullIntensity: 0.75,
            maxVolume: 0.8,
          ),
          MusicStemLayer(
            assetId: 'choir',
            minIntensity: 0.5,
            fullIntensity: 0.5,
          ),
        ]);
      final voices = mixer.activeVoices;
      final previous = <double>[-1, -1, -1];

      for (var step = 0; step <= 20; step++) {
        music.targetIntensity = step / 20;
        settle(music);
        for (var i = 0; i < voices.length; i++) {
          expect(
            voices[i].sourceVolume,
            greaterThanOrEqualTo(previous[i] - 1e-9),
            reason: 'stem $i at intensity ${step / 20}',
          );
          previous[i] = voices[i].sourceVolume;
        }
      }
    });

    test('a default stem is an always-on base layer; a stem with a positive '
        'minIntensity fades in from silence', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final music = controllerWith(mixer)
        ..startLayeredStems(<MusicStemLayer>[
          MusicStemLayer(assetId: 'pad', maxVolume: 0.7),
          MusicStemLayer(
            assetId: 'drums',
            minIntensity: 0.25,
            fullIntensity: 0.75,
            maxVolume: 0.8,
          ),
          MusicStemLayer(
            assetId: 'choir',
            minIntensity: 0.5,
            fullIntensity: 0.5,
          ),
        ]);
      final pad = mixer.activeVoices[0];
      final drums = mixer.activeVoices[1];
      final choir = mixer.activeVoices[2];

      expect(pad.sourceVolume, 0.7);
      expect(drums.sourceVolume, 0.0);
      expect(choir.sourceVolume, 0.0);

      music.targetIntensity = 0.1;
      settle(music);
      expect(pad.sourceVolume, 0.7);
      expect(drums.sourceVolume, 0.0);

      music.targetIntensity = 0.5;
      settle(music);
      expect(pad.sourceVolume, 0.7);
      // Half-way up the smoothstep ramp.
      expect(drums.sourceVolume, closeTo(0.4, 1e-3));
      expect(choir.sourceVolume, closeTo(1.0, 1e-3));

      music.targetIntensity = 1.0;
      settle(music);
      expect(drums.sourceVolume, closeTo(0.8, 1e-6));
    });

    test('a cross-fade fades the outgoing track down from its own volume', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final music = AdaptiveMusicController(mixer: mixer)
        ..playTrack('calm', volume: 0.3, crossfadeSeconds: 0.0);
      final calm = mixer.activeVoices.single;
      expect(calm.sourceVolume, closeTo(0.3, 1e-9));

      music.playTrack('battle', crossfadeSeconds: 2.0);
      final battle = mixer.activeVoices.last;

      var previous = calm.sourceVolume;
      for (var i = 0; i < 19; i++) {
        music.update(0.1);
        expect(calm.sourceVolume, lessThanOrEqualTo(previous + 1e-9));
        previous = calm.sourceVolume;
      }
      // 1.9 s into a 2 s fade.
      expect(calm.sourceVolume, closeTo(0.3 * 0.05, 1e-6));
      expect(battle.sourceVolume, closeTo(0.95, 1e-6));

      music.update(0.2);
      expect(calm.isStopped, isTrue);
      expect(battle.sourceVolume, closeTo(1.0, 1e-9));
    });

    test('switching tracks in mid cross-fade fades the half-risen track out '
        'from where it is', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final music = AdaptiveMusicController(mixer: mixer)
        ..playTrack('a', crossfadeSeconds: 0.0)
        ..playTrack('b', crossfadeSeconds: 1.0)
        ..update(0.25);
      final b = mixer.activeVoices.last;
      expect(b.sourceVolume, closeTo(0.25, 1e-9));

      music
        ..playTrack('c', crossfadeSeconds: 1.0)
        ..update(0.1);
      expect(b.sourceVolume, lessThanOrEqualTo(0.25));
      expect(b.sourceVolume, closeTo(0.25 * 0.9, 1e-9));
    });
  });

  group('BgmTransportStack and musical effects', () {
    const track = LoopRegionTrack(assetId: 'overworld', durationSeconds: 30.0);

    test('a BGM that is fading out to stop stays stopped when a musical '
        'effect ends', () {
      final backend = InMemoryAudioBackend();
      final mixer = AudioMixer(backend: backend);
      final bgm = BgmTransportStack(mixer: mixer)..playBgm(track);
      bgm.update(1.0);
      mixer.update(1.0);

      bgm
        ..stopBgm(fadeOutSeconds: 2.0)
        ..playMusicalEffect('fanfare', durationSeconds: 0.5);

      var loudest = 0.0;
      for (var i = 0; i < 100; i++) {
        bgm.update(0.1);
        mixer.update(0.1);
        if (bgm.effectiveBgmVolume > loudest) {
          loudest = bgm.effectiveBgmVolume;
        }
      }

      expect(bgm.isMusicalEffectPlaying, isFalse);
      expect(bgm.activeTrack, isNull);
      expect(bgm.effectiveBgmVolume, 0.0);
      // Paused under the fanfare, then gone: it never came back up.
      expect(loudest, 0.0);
      expect(
        backend.activeVoices.values.where((v) => v.assetId == 'overworld'),
        isEmpty,
      );
    });

    test('a ducked BGM that is fading out keeps falling after the effect and '
        'then stops', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final bgm = BgmTransportStack(mixer: mixer)
        ..playBgm(track)
        ..stopBgm(fadeOutSeconds: 4.0)
        ..playMusicalEffect('sting', durationSeconds: 1.0, bgmDuckGain: 0.5);

      var previous = bgm.effectiveBgmVolume;
      for (var i = 0; i < 60; i++) {
        bgm.update(0.1);
        expect(bgm.effectiveBgmVolume, lessThanOrEqualTo(previous + 1e-9));
        previous = bgm.effectiveBgmVolume;
      }
      expect(bgm.activeTrack, isNull);
    });

    test('a playing BGM is paused under the effect and fades back in after '
        'it', () {
      final mixer = AudioMixer(backend: InMemoryAudioBackend());
      final bgm = BgmTransportStack(mixer: mixer)
        ..playBgm(track)
        ..update(2.0)
        ..playMusicalEffect(
          'fanfare',
          durationSeconds: 1.0,
        );
      final cursorAtEffect = bgm.cursorSeconds;

      bgm.update(0.5);
      expect(bgm.effectiveBgmVolume, 0.0);
      expect(bgm.cursorSeconds, cursorAtEffect);

      bgm.update(0.75);
      expect(bgm.isMusicalEffectPlaying, isFalse);
      expect(bgm.effectiveBgmVolume, closeTo(0.5, 1e-9));
      bgm.update(0.5);
      expect(bgm.effectiveBgmVolume, 1.0);
      expect(bgm.activeTrack, same(track));
    });
  });
}
