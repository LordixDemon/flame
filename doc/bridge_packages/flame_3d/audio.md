# Spatial Audio

`package:flame_3d/audio.dart` works out how sounds placed in the 3D world should be heard from where
the camera or the player is: how loud, how far to the left or right, at what pitch, how muffled by
walls and with how much reverb. It does not play audio. It hands these numbers, per sound and per
frame, to an audio engine that you connect to it, such as `audioplayers` (the engine under
`flame_audio`).

- `SpatialAudioListener3D` is the ears, usually on the camera.
- `SpatialAudioEmitter3D` is a sound source in the world: distance rolloff, a directional cone,
  Doppler pitch and an optional occlusion raycast. On its own, it reports a `SpatialMix3D` (volume,
  pan, pitch) every frame.
- `SpatialAudioMixer3D` manages many emitters: it keeps the loudest ones on a limited number of
  real voices of your engine through an `AudioVoiceBackend3D`, tracks the rest as virtual voices,
  turns occlusion into a low-pass cutoff and blends reverb settings from `AudioZone3D`s.

All of it is CPU work in Dart on the game's update, on every platform.


## The listener

```dart
final listener = SpatialAudioListener3D(camera: camera);
world.add(listener);
```

The listener takes its position and orientation, in this order of preference, from a `camera`
(its eye, its right and up vectors, looking along -Z of the view), from a `target` component (its
world transform, -Z forward and +Y up), or from its own transform as a `Component3D` (for example
as a child of the player model). The right vector decides the stereo pan.

| Option                | Default | Meaning                                                      |
|-----------------------|---------|--------------------------------------------------------------|
| `speedOfSound`        | `343.0` | Units per second, for Doppler.                               |
| `dopplerFactor`       | `1.0`   | Scales the Doppler effect of all emitters; `0` turns it off. |
| `autoComputeVelocity` | `true`  | Derive `velocity` from the movement between updates.         |

The velocity is computed in the listener's `update`, so the listener must be mounted for it, or
set `autoComputeVelocity: false` and write `velocity` yourself.


## Emitters

An emitter is a `Component3D`: put it where the sound comes from, or attach it to a moving object
(a child of a model, of a `BoneSocket3D`, of a vehicle) and it follows:

```dart
final torch = SpatialAudioEmitter3D(
  clipId: 'torch_loop',
  clipDuration: 6.0,
  minDistance: 2.0,
  maxDistance: 25.0,
  listener: listener,
  onMixChanged: (mix) {
    // mix.volume in [0, 1], mix.pan in [-1, 1], mix.pitch around 1
  },
  position: Vector3(3, 1.2, -4),
);
world.add(torch);
```

Each update, an emitter evaluates its mix for its `listener` and calls `onMixChanged` with it;
`lastMix` keeps the last one, and `evaluateMix(listener)` computes one on demand. Without a
`listener`, it uses the first `SpatialAudioListener3D` mounted in its world (listeners register
with their world when they mount, so nothing is searched). When a [mixer](#the-mixer) evaluates
the emitter, the emitter does not evaluate itself again: the mixer calls `onMixChanged` with its
own evaluation.

The volume is `baseVolume` times the distance gain, the cone gain and the occlusion gain, clamped
to `[0, max(1, baseVolume)]`. The pan is the direction of the emitter projected on the listener's
right vector, from `-1` (left) to `1` (right); a sound straight ahead, behind, above or below has a
pan of `0`.


### Distance rolloff

The distance `d` from the listener is first clamped to `[minDistance, maxDistance]` (defaults `1`
and `50`), then:

| `attenuationModel`          | Gain                                                            |
|-----------------------------|-----------------------------------------------------------------|
| `inverseDistance` (default) | `minDistance / (minDistance + rolloff * (d - minDistance))`     |
| `linear`                    | `1 - rolloff * (d - minDistance) / (maxDistance - minDistance)` |
| `exponential`               | `(d / minDistance) ^ -rolloff`                                  |

The result is clamped to `[0, 1]`; `rolloff` defaults to `1`. These are the clamped distance
models of OpenAL and Web Audio: closer than `minDistance` a sound plays at full volume, and with
`inverseDistance` and `exponential` it stops getting quieter at `maxDistance` instead of going
silent (with the defaults it stays at 1/50 of its volume). Use `linear` for sounds that must fade
out completely at `maxDistance`.


### Directional cones

A loudspeaker or a mouth is louder in front. `innerConeRad` and `outerConeRad` are full cone angles
around the emitter's `localForward` (default `(0, 0, -1)`, rotated by the emitter's world
transform). Inside the inner cone the cone gain is `1`, outside the outer cone it is
`outerConeGain` (default `0.25`), and between them it changes linearly with the angle. Both
default to `2 * pi`, which turns the cone off.


### Doppler

The pitch is `(c - k * vl) / (c - k * vs)`, where `c` is the listener's `speedOfSound`, `k` is the
product of the emitter's and the listener's `dopplerFactor`, and `vs` and `vl` are the emitter's and
listener's velocities along the line from the emitter to the listener. The velocities are clamped
below the speed of sound and the pitch to `[minPitch, maxPitch]` (defaults `0.5` and `2.0`). With
`autoComputeVelocity` (the default) an emitter derives its velocity from its movement between
updates, which needs it to be mounted.


### Occlusion

With `enableOcclusion: true`, every evaluation casts a ray from the emitter to the listener through
the emitter's `World3D` (`World3D.raycast`, see [Against a scene](geometry.md#against-a-scene)). Any
hit makes the sound occluded: `mix.occluded` is `true` and the volume is multiplied by
`occlusionGain` (default `0.35`). The emitter, the listener, their ancestors and the listener's
`target` never occlude; an `occlusionFilter` chooses which other objects do:

```dart
final behindWall = SpatialAudioEmitter3D(
  enableOcclusion: true,
  occlusionGain: 0.3,
  occlusionFilter: (object) => object is MeshComponent,
  listener: listener,
);
```

The test is all or nothing, and it uses the triangles of every mesh in the world, also small props
and invisible meshes (raycasts ignore `visible`), unless the filter excludes them. It costs one
raycast per evaluation.


## Making sound

The mixer drives an `AudioVoiceBackend3D`, three methods that you implement on top of an audio
engine: `startVoice` returns a handle for a new real voice, `updateVoice` applies new parameters to
it, and `stopVoice` releases it. Each call receives the emitter and an `AudioVoiceParams3D`:

| Field              | Meaning                                             |
|--------------------|-----------------------------------------------------|
| `clipId`           | The emitter's `clipId`: which sound to play.        |
| `volume`           | Final gain, usually in `[0, 1]`.                    |
| `pan`              | Stereo position from `-1` to `1`.                   |
| `pitch`            | Doppler pitch factor.                               |
| `lowPassCutoffHz`  | Cutoff for a low-pass filter, lower when occluded.  |
| `occlusion`        | Occlusion amount from `0` (clear) to `1` (blocked). |
| `playbackPosition` | Where in the clip the sound is, in seconds.         |
| `looping`          | The emitter's `looping`.                            |
| `reverb`           | The current `ReverbPreset3D` at the listener.       |

A backend for `audioplayers` (add `audioplayers`, or `flame_audio`, to the game's dependencies)
can apply the volume, the pan (`setBalance`) and the playback position; it has no filters or
reverb, so `lowPassCutoffHz` and `reverb` need an engine that has them. `setPlaybackRate` changes
the speed, which is how a pitch shift is usually approximated with it (its documentation limits
it to 0.5 to 2 on iOS and macOS). Platform calls are not free, so the example below sends a value
only when it has changed noticeably:

```dart
class AudioplayersBackend implements AudioVoiceBackend3D {
  final Map<int, AudioPlayer> _players = {};
  final Map<int, AudioVoiceParams3D> _sent = {};
  int _nextHandle = 0;

  @override
  int startVoice(SpatialAudioEmitter3D emitter, AudioVoiceParams3D params) {
    final handle = _nextHandle++;
    final player = AudioPlayer();
    _players[handle] = player;
    _sent[handle] = params;
    unawaited(
      player.setReleaseMode(
        params.looping ? ReleaseMode.loop : ReleaseMode.stop,
      ),
    );
    unawaited(
      player.play(
        AssetSource('audio/${params.clipId}.ogg'),
        volume: params.volume,
        balance: params.pan,
        position: Duration(
          milliseconds: (params.playbackPosition * 1000).round(),
        ),
      ),
    );
    return handle;
  }

  @override
  void updateVoice(
    int voiceHandle,
    SpatialAudioEmitter3D emitter,
    AudioVoiceParams3D params,
  ) {
    final player = _players[voiceHandle];
    final last = _sent[voiceHandle];
    if (player == null || last == null) {
      return;
    }
    if ((params.volume - last.volume).abs() > 0.01 ||
        (params.pan - last.pan).abs() > 0.02 ||
        (params.pitch - last.pitch).abs() > 0.01) {
      unawaited(player.setVolume(params.volume));
      unawaited(player.setBalance(params.pan));
      unawaited(player.setPlaybackRate(params.pitch));
      _sent[voiceHandle] = params;
    }
  }

  @override
  void stopVoice(int voiceHandle, SpatialAudioEmitter3D emitter) {
    _sent.remove(voiceHandle);
    unawaited(_players.remove(voiceHandle)?.dispose());
  }
}
```

Creating a player per voice adds start-up latency; a backend for many short sounds would keep a
pool of players with their sources set in advance.


## The mixer

```dart
final mixer = SpatialAudioMixer3D(
  backend: AudioplayersBackend(),
  listener: listener,
  maxRealVoices: 8,
);
world.add(mixer);
```

Mounted in a `World3D`, the mixer uses every `SpatialAudioEmitter3D` and `AudioZone3D` mounted
in that world: they register with their world when they mount and leave when they are removed, so
the mixer does not walk the component tree. An emitter removed from the world while it plays has
its voice stopped and is forgotten at once. `registerEmitter` and `registerZone` add emitters and
zones that are not in the world (the `emitters` and `zones` constructor lists do the same); those
stay until `unregisterEmitter` or `unregisterZone`. `unregisterEmitter` on an emitter of the world
stops its voice and keeps it out of the mix until `registerEmitter` is called for it or it is
removed from the world. Without a `listener`, the mixer uses the first listener mounted in its
world. Each update it:

1. evaluates the mix of every emitter whose `playing` is `true`, and passes it to the emitter's
   `onMixChanged`;
2. advances the emitter's `playbackPosition` by `dt` times its pitch, wrapping around
   `clipDuration` for looping sounds; a sound that is not looping stops (`playing` becomes `false`)
   when it reaches `clipDuration`. A `clipDuration` of `0` (the default) means unknown: the
   position keeps growing and the sound never ends by itself;
3. scores every emitter whose final volume is at least `virtualThresholdVolume`:
   `volume * max(0.1, 1 + audioPriority * 0.1)`, plus `0.015` for emitters that already have a
   real voice, so two equally loud sounds do not swap voices every frame;
4. gives real voices to the `maxRealVoices` best scores: voices that lost their place are stopped
   with `stopVoice`, kept voices get `updateVoice`, and new ones get `startVoice`, starting at the
   emitter's current `playbackPosition`, so a sound that comes back from being virtual resumes
   where it would be.

The other playing emitters are virtual voices: they use no engine voice but are still evaluated
every update (with their occlusion raycast, if any), and keep their position. `realVoiceCount`,
`virtualVoiceCount`, `isEmitterReal` and `voiceParamsFor` tell the state. `stopAllRealVoices`
stops everything, and removing the mixer does it too.

The mixer tells the backend where the sound should be in the clip, but the engine plays on its own
clock; a backend that wants to stay in step can seek when the two drift apart.

| Option                   | Default | Meaning                                             |
|--------------------------|---------|-----------------------------------------------------|
| `maxRealVoices`          | `16`    | Real voices at most; `0` keeps every sound virtual. |
| `virtualThresholdVolume` | `0.005` | Quieter sounds never get a real voice.              |
| `maxLowPassCutoffHz`     | `20000` | Cutoff when nothing occludes.                       |
| `minLowPassCutoffHz`     | `800`   | Cutoff when fully occluded.                         |
| `reverbCrossfadeSpeed`   | `5.0`   | Reverb blend rate per second; `0` switches at once. |
| `defaultReverb`          | `dry`   | Reverb outside every zone.                          |

`audioPriority` (the `priority` argument of the emitter's constructor) is separate from the
component `priority`, which orders a component among its siblings for updates and rendering. With
the default `inverseDistance` model a sound never gets quieter than its
gain at `maxDistance`, which is above the default threshold, so every playing emitter competes for
the real voices however far it is; use `linear`, or a higher threshold, to drop distant sounds.


### Occlusion in the mixer

Without an `occlusionQuery`, the mixer uses each emitter's own raycast (when `enableOcclusion` is
on): occlusion is `0` or `1`. With an `occlusionQuery`, a function of the listener and emitter
positions returning `0` (clear) to `1` (blocked), the emitters' raycasts are skipped (the mix
passed to `onMixChanged` is then not occluded; the occlusion is in the voice parameters) and the
occlusion can be partial, for example the fraction of several rays that hit:

```dart
mixer.occlusionQuery = (listenerPos, emitterPos) {
  final ray = Ray.originDirection(emitterPos, listenerPos - emitterPos);
  final hit = world.raycast(
    ray,
    maxDistance: listenerPos.distanceTo(emitterPos),
  );
  return hit == null ? 0.0 : 0.8;
};
```

With a query, the volume is multiplied by `1 - occlusion * (1 - occlusionGain)`. In both cases the
low-pass cutoff goes from `maxLowPassCutoffHz` at `0` to `minLowPassCutoffHz` at `1`, evenly on a
logarithmic scale.


## Zones and reverb

An `AudioZone3D` is a volume with a `ReverbPreset3D`: a sphere of `radius` (default `8`) or, with
`halfExtents`, a box that follows the zone's position, rotation and scale. The zone's weight at a
point is `1` inside and falls to `0` over `fadeDistance` (default `2`) outside, along a smoothstep.

```dart
world.add(
  AudioZone3D(
    preset: ReverbPreset3D.cave,
    halfExtents: Vector3(6, 3, 10),
    fadeDistance: 1.5,
    position: Vector3(0, 3, -20),
  ),
);
```

Each update, the mixer starts from `defaultReverb` and, for every enabled zone in ascending
`audioPriority` (the `priority` argument of the zone's constructor, separate from the component
`priority`), blends toward the zone's preset by the zone's weight at the listener, so a zone with a
higher priority inside another one wins. The result is approached smoothly (a factor of
`1 - exp(-reverbCrossfadeSpeed * dt)` per update), stored in `currentReverb`, passed to
`onReverbChanged` on the updates where it changes, and handed to every voice in its `reverb`
field.

A `ReverbPreset3D` is three numbers for your engine's reverb, `wetMix`, `decaySeconds` and
`preDelayMs`, plus a `name`. The built-in presets:

| Preset      | `wetMix` | `decaySeconds` | `preDelayMs` |
|-------------|----------|----------------|--------------|
| `dry`       | `0.0`    | `0.2`          | `0`          |
| `room`      | `0.25`   | `0.9`          | `8`          |
| `cave`      | `0.6`    | `2.8`          | `24`         |
| `cathedral` | `0.78`   | `4.5`          | `42`         |

The mixer produces only these numbers; applying a reverb is up to the engine behind the backend.


## Cost per frame

All costs are on the CPU, in the game update.

- Every emitter is evaluated once per frame: by itself in its `update`, or by the mixer when one
  mixes it. An evaluation costs a few dozen arithmetic operations, plus one raycast when
  `enableOcclusion` is on, and allocates a small `SpatialMix3D`.
- The mixer goes through the emitters and zones of its world in a list (no tree walk) and
  allocates one `AudioVoiceParams3D` per playing emitter per update, the value it hands to the
  backend; its other working lists are reused.
- Virtual voices are evaluated like real ones, raycast included.

A few dozen emitters cost little; for hundreds, prefer an `occlusionQuery` that you can throttle
over per-emitter raycasts, and use `linear` rolloff so that distant sounds drop out.


## Limitations

- Nothing here plays sound: an `AudioVoiceBackend3D` must be written for an audio engine, and the
  package ships none.
- Panning is a stereo pan from the left-right direction only: no distinction between front and
  back, no elevation and no head-related filtering.
- The low-pass cutoff and the reverb are parameters only; the engine must provide the filter and
  the reverb.
- Built-in occlusion is a single all-or-nothing ray that also hits invisible meshes.
