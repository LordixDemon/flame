# Cinematics

`package:flame_3d/cinematics.dart` has two tools for scripted camera work and cutscenes:

- a camera director: `VirtualCamera3D` shots placed in the world, and a `VirtualCameraBrain3D`
  that picks the shot with the highest priority and moves a real `CameraComponent3D` to it, with a
  blend when the shot changes;
- a sequencer: `Timeline3D` plays tracks of keyframes and cues against one playhead (camera shots,
  transforms, skeletal clips, morph weights, events), forwards, backwards or scrubbed.

Both run on the CPU in `update`. They add no render pass and no draw call: they only write
transforms, camera parameters and animation clocks that the renderer reads anyway.


## Virtual cameras and the brain


### A shot

A `VirtualCamera3D` is a `Component3D` without geometry: its world transform is the eye of a shot.
Add it to the world like any other component, or as a child of something that moves (a car, a
character) so that the shot follows it. Without a `lookAtTarget` the shot looks down its local
`-Z` axis, turned by its `rotation`; with one it aims at the target's origin plus `lookAtOffset`,
keeping `up` as the reference up direction.

```dart
final hero = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
final wide = VirtualCamera3D(
  priority: 10,
  position: Vector3(0, 4, 12),
  lookAtTarget: hero,
  lookAtOffset: Vector3(0, 1, 0),
  fovY: 55,
);
final closeUp = VirtualCamera3D(
  priority: 20,
  enabled: false,
  position: Vector3(2, 2, 3),
  lookAtTarget: hero,
  damping: 6,
  blendDurationOverride: 1.2,
);

final camera = CameraComponent3D();
final game = FlameGame3D(
  world: World3D(children: [hero, wide, closeUp]),
  camera: camera,
);
game.add(VirtualCameraBrain3D(camera: camera, blendDuration: 0.6));

// Later: blend to the close-up over 1.2 s.
closeUp.enabled = true;
```

| Option                  | Default     | Meaning                                                |
| ----------------------- | ----------- | ------------------------------------------------------ |
| `priority`              | `0`         | the enabled shot with the highest priority wins        |
| `enabled`               | `true`      | disabled shots are never chosen                        |
| `fovY`                  | `60`        | vertical field of view in degrees                      |
| `lookAtTarget`          | `null`      | a `Component3D` to aim at                              |
| `lookAtOffset`          | zero        | world-space offset added to the target's origin        |
| `up`                    | `(0, 1, 0)` | up direction when aiming; `(0, 0, 1)` in z-up scenes   |
| `damping`               | `0`         | smoothing rate (1/s) of position and rotation          |
| `blendWeight`           | `1`         | `0..1`: `0` excludes the shot, below `1` stops partway |
| `blendDurationOverride` | `null`      | seconds of the blend into this shot                    |
| `blendCurveOverride`    | `null`      | easing curve of the blend into this shot               |

With `damping` above zero the shot's pose follows its raw pose exponentially
(`1 - exp(-damping * dt)` of the remaining distance per update), which takes the edge off a
jittery target. `resetDampingState()` makes the next evaluation snap.


### The brain

`VirtualCameraBrain3D` is a plain Flame `Component`: add it to the game (or anywhere in the tree).
On every `update` it:

1. collects the candidates: the cameras given in `cameras` or `registerCamera`, then every
   `VirtualCamera3D` found under its world (the `world` argument, else `camera.world`, else the
   nearest `World3D` ancestor);
2. picks the enabled candidate with `blendWeight > 0` and the highest `priority` (on a tie, the
   first one found);
3. when the winner changed, starts a blend from the camera's current output pose, over the winner's
   `blendDurationOverride` or the brain's `blendDuration` (default `0.5` s), eased by the winner's
   `blendCurveOverride` or the brain's `blendCurve` (default `Curves.easeInOut`). The very first
   shot is a cut;
4. writes `position`, `target` (one unit ahead), `up`, `rotation` and `fovY` of `camera`. The
   position is interpolated linearly, the rotation along the shortest arc, the field of view
   linearly.

When no shot is enabled the camera keeps its last pose. `activeCamera`, `previousCamera`,
`isBlending` and `blendProgress` (`0..1`) tell what the brain is doing. `evaluate(dt)` runs one
step by hand, for example in a test.

A `blendWeight` below `1` keeps the output partway: the camera stays at that fraction of the way
from the pose it had when the shot became active to the shot.


### Working with the camera rigs

The rigs of [Cameras](cameras.md) write the same camera fields as the brain, so whichever updates
last in a frame wins:

- do not drive one camera with the brain and `OrbitCameraController3D`, `SpringArmCamera3D` or
  `CameraDollyTrack3D` at the same time. Hand over by disabling every shot (the brain then leaves
  the camera alone) before the rig takes control;
- `CameraShake3D` layers on top of whatever pose the camera has: it removes its own offset of the
  previous frame and adds a new one. Let it update after the brain (a higher `priority`, or add it
  later to the same parent);
- to move a shot, move the `VirtualCamera3D` itself: parent it to a moving component, key it with a
  `TransformTrack3D` (below), or animate it with the 3D effects of
  [Input and Effects](input_and_effects.md);
- a custom view matrix (`CameraComponent3D.customViewMatrix`) takes precedence over the pose the
  brain writes; an orthographic camera ignores `fovY`.

A `Scene3DComponent` layer has no `CameraComponent3D` of its own. Give the brain an unmounted
camera as its output and copy its matrices into the layer's projection after the brain has
updated, with the aspect ratio of the layer:

```dart
final output = CameraComponent3D(viewport: FixedSizeViewport(400, 300));
final brain = VirtualCameraBrain3D(camera: output, world: layer.world);

// Each frame, after the brain has updated:
layer.projection = Scene3DProjection.camera(
  viewMatrix: output.viewMatrix,
  projectionMatrix: output.projectionMatrix,
  rect: Rect.fromLTWH(0, 0, layer.size.x, layer.size.y),
);
```


## Timelines


### Building a timeline

A `Timeline3D` is a Flame `Component` holding a list of tracks. Its `duration` is the latest end
time of its tracks unless a `duration` is given. Add it to the game and call `play()` (or pass
`autoPlay: true`):

```dart
final timeline = Timeline3D(
  tracks: [
    CameraShotTrack3D(
      shots: [
        CameraShot3D(camera: wide, startTime: 0, endTime: 2),
        CameraShot3D(camera: closeUp, startTime: 2, endTime: 4),
      ],
    ),
    TransformTrack3D(
      target: door,
      rotationKeys: [
        TransformKeyframe3D(time: 1, value: Quaternion.identity()),
        TransformKeyframe3D(
          time: 2.5,
          value: Quaternion.axisAngle(Vector3(0, 1, 0), -1.4),
        ),
      ],
    ),
    EventMarkerTrack3D(
      markers: [
        EventMarker3D(name: 'creak', time: 1, onTrigger: playCreak),
      ],
    ),
  ],
  onComplete: () => print('cutscene finished'),
);
game.add(timeline..play());
```

A camera shot track needs a `VirtualCameraBrain3D` driving the camera. Let the timeline update
before the brain (add it first, or give it a lower `priority`), otherwise the cut reaches the
camera one frame late.


### Playback

- `play()` starts or resumes from `currentTime`; a non-looping timeline that sits at the end it
  plays towards starts over from the other end: from `0` playing forwards, from `duration` playing
  backwards. `pause()` keeps the playhead, `stop()` rewinds to `0`.
- `speed` scales time (`1` by default); a negative speed plays backwards, so
  `timeline..speed = -1..play()` plays a stopped timeline from its end, and `seek(t)` followed by
  `play()` plays backwards from `t`. `loop` wraps around at either end, otherwise playback stops at
  the end (or at `0` backwards) and calls `onComplete`.
- Every update while playing evaluates every enabled track at the playhead. Tracks are evaluated
  at an absolute time, not by accumulating steps, so jumping around gives the same result as
  playing.
- `seek(seconds)` moves the playhead (clamped to `[0, duration]`), evaluates the tracks, and fires
  the markers it crosses in the direction of the jump; `seek(seconds, fireEvents: false)` is the
  call for an editor's scrub bar.
- `addTrack` appends a track; `enabled` on a track switches it off.

The timeline advances by the `dt` its `update` receives, times `speed`: pausing the game pauses
it, and a time scale on an ancestor (Flame's `HasTimeScale`) slows it like any other component.


### Transform tracks

`TransformTrack3D` keys the local `position`, `rotation` and `scale` of a `Component3D`, each
channel with its own keys. Before the first key and after the last one the channel holds the
key's value. A key's `interpolation` applies to the segment that starts at it:

- `step` holds the key's value until the next key;
- `linear` (the default) interpolates vectors linearly and rotations along the shortest arc;
- `cubicHermite` uses the key's `outTangent` and the next key's `inTangent`, in units per second,
  a missing tangent counting as zero. Rotations are interpolated component by component and
  normalized, as glTF cubic splines are. Without either tangent the segment is eased with
  `3t² - 2t³` instead (along the shortest arc for rotations).

```dart
final arc = TransformTrack3D(
  target: ball,
  positionKeys: [
    TransformKeyframe3D(
      time: 0,
      value: Vector3.zero(),
      interpolation: TimelineInterpolation3D.cubicHermite,
      outTangent: Vector3(0, 8, 0), // leaves upwards at 8 units/s
    ),
    TransformKeyframe3D(
      time: 1,
      value: Vector3(4, 0, 0),
      inTangent: Vector3(0, -8, 0), // arrives downwards
    ),
  ],
);
```


### Camera shot tracks

`CameraShotTrack3D` holds `CameraShot3D`s, each a `camera` active from `startTime` to `endTime`.
While a shot is active its camera is enabled with the shot's `activePriority` (default `100`) and,
when the shot has one, its `blendDurationOverride`; every other camera of the track is disabled
and gets back the priority and blend duration override it had when the track was built. When
shots overlap, the one that starts later wins; the end of the last shot is included. The brain
then cuts or blends between the cameras as usual.

Where no shot covers the playhead (before the first shot, in a gap between shots, after the last
one when the timeline's `duration` is longer), every camera of the track is disabled: the brain
switches to another enabled camera, or keeps the camera where it was when there is none. The track
owns the `enabled` flag of every camera it lists: keep a fallback camera that should stay
available outside the track.


### Skeletal clip and morph weight tracks

`AnimationClipTrack3D` places `ModelAnimation` clips of a `ModelComponent` on the timeline. An
`AnimationClipSpan3D` starts at `startTime`, ends at `endTime` (by default
`startTime + animation.lastTime / |speed|`), starts the clip at `clipOffset` seconds, plays it at
`speed` and optionally loops it. When spans overlap the later one wins. At each evaluation the
track starts the clip on the model if needed, sets its clock and evaluates the pose.

While the playhead is inside a span the track owns the model's clock: it holds the model's
`animationState.speed` at `0`, so the clip does not advance on its own while the timeline is
paused or scrubbed, nor run a frame ahead of the playhead. When the playhead leaves every span the
model gets back the speed it had and plays on from where the timeline left it;
`releaseModelClock()` gives it back at once, and a timeline removed from the game does so for its
tracks.

`MorphWeightTrack3D` keys the morph target weights of a `ModelComponent` (of the node named
`nodeName`, or all nodes), with the same interpolation modes; `cubicHermite` reads per-weight
`inTangents` and `outTangents`. `currentWeights` holds the last evaluated weights.

```dart
final wave = character.model.animations.firstWhere((a) => a.name == 'Wave');
final clips = AnimationClipTrack3D(
  target: character,
  clips: [AnimationClipSpan3D(animation: wave, startTime: 0.5, speed: 1.2)],
);
final smile = MorphWeightTrack3D(
  target: character,
  nodeName: 'Head',
  keyframes: [
    MorphWeightKeyframe3D(time: 0, weights: const [0]),
    MorphWeightKeyframe3D(time: 0.8, weights: const [1]),
  ],
);
```


### Event markers

`EventMarkerTrack3D` fires `EventMarker3D` cues when the playhead crosses their `time`: during
forward and backward playback, across a loop's wrap-around, and on `seek` (unless
`fireEvents: false`). Each marker can have an `onTrigger` callback, a direction-aware
`onDirectionalTrigger`, and a `payload`; the track's `onMarker` receives every marker. A marker at
time `0` fires on the first update or seek after the timeline is created, stopped or rewound, and
again at each wrap-around of a looping timeline.

```dart
final cues = EventMarkerTrack3D(
  markers: [
    EventMarker3D(name: 'impact', time: 1.25, payload: 3),
    EventMarker3D(
      name: 'door',
      time: 2,
      onDirectionalTrigger: (marker, direction) {
        if (direction == TimelineDirection3D.forward) {
          print('open');
        } else {
          print('close');
        }
      },
    ),
  ],
  onMarker: (marker, direction) => print('${marker.name} ${direction.name}'),
);
```


### Custom tracks

Any other property can be keyed by extending `TimelineTrack3D`: give it an `endTime` and apply the
value for a given time in `evaluate`. `evaluate` must depend on the time alone, so that seeking
works:

```dart
class CallbackTrack3D extends TimelineTrack3D {
  CallbackTrack3D({required this.length, required this.apply});

  final double length;
  final void Function(double time) apply;

  @override
  double get endTime => length;

  @override
  void evaluate(double time) => apply(time);
}
```


## Limitations

- `AnimationClipTrack3D` does not blend between overlapping spans: the later one wins.
- The brain walks the whole tree of its world on every update to find the virtual cameras
  (recursively, with a linear duplicate check per camera found). With 10,000 components that took
  about 0.1 ms per update in a JIT test run; the cost grows with the size of the world.
- There are no per-key easing curves besides `step`, `linear` and `cubicHermite`, no audio or
  property tracks other than the ones above, and a timeline cannot be saved or loaded.

The behavior described here is covered by
`test/cinematics/timeline_and_virtual_cameras_3d_test.dart` (shot selection, damping, blending,
every track type, markers in both directions, looping, reverse playback from the end, the model
clock held by a clip track, shot overrides given back, single rotation tangents).
