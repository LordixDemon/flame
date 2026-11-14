import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/src/canvas3d/deformable_mesh_3d.dart';
import 'package:flame/src/canvas3d/node_uv_decal_3d.dart';
import 'package:meta/meta.dart';

/// Frame-synchronized marker fired by [AnimationMixer3D] when playback crosses
/// [time] seconds inside an [AnimationClip3D].
@immutable
class const AnimationEvent3D({
  required final double time,
  required final String name,
});

/// Keyframed 3D transform track (translation `(dx, dy, dz)`, unit quaternion
/// `(qx, qy, qz, qw)` via SLERP, and scale `(sx, sy, sz)`) targeting either a
/// [Bone3D] index in [SkinnedMeshWorkspace3D] or a [Node3D].
class TransformTrack3D({
  required final int targetIndex,
  required final Float32List times,
  final String targetName = '',
  final Float32List? translations,
  final Float32List? rotations,
  final Float32List? scales,
}) {
  this
    : assert(times.isNotEmpty, 'times must not be empty'),
      assert(
        translations == null || translations.length == times.length * 3,
        'translations length must equal times.length * 3',
      ),
      assert(
        rotations == null || rotations.length == times.length * 4,
        'rotations length must equal times.length * 4',
      ),
      assert(
        scales == null || scales.length == times.length * 3,
        'scales length must equal times.length * 3',
      );

  /// Number of keyframes in this track.
  int get keyframeCount => times.length;

  static (int i0, int i1, double alpha) _locateSegment(
    Float32List times,
    double t,
  ) {
    final n = times.length;
    if (n == 1 || t <= times[0]) {
      return (0, 0, 0.0);
    }
    final last = n - 1;
    if (t >= times[last]) {
      return (last, last, 0.0);
    }
    var lo = 0;
    var hi = last;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = times[hi] - times[lo];
    final alpha = span > 1e-9 ? ((t - times[lo]) / span).clamp(0.0, 1.0) : 0.0;
    return (lo, hi, alpha);
  }

  /// Samples `(dx, dy, dz, qx, qy, qz, qw, sx, sy, sz)` at time [t] using
  /// `O(log K)` binary search and shortest-arc SLERP.
  ({
    double dx,
    double dy,
    double dz,
    double qx,
    double qy,
    double qz,
    double qw,
    double sx,
    double sy,
    double sz,
  })
  sample(double t) {
    final (i0, i1, alpha) = _locateSegment(times, t);

    var dx = 0.0;
    var dy = 0.0;
    var dz = 0.0;
    final tr = translations;
    if (tr != null) {
      final a3 = i0 * 3;
      if (i0 == i1 || alpha <= 0.0) {
        dx = tr[a3];
        dy = tr[a3 + 1];
        dz = tr[a3 + 2];
      } else {
        final b3 = i1 * 3;
        dx = tr[a3] + (tr[b3] - tr[a3]) * alpha;
        dy = tr[a3 + 1] + (tr[b3 + 1] - tr[a3 + 1]) * alpha;
        dz = tr[a3 + 2] + (tr[b3 + 2] - tr[a3 + 2]) * alpha;
      }
    }

    var qx = 0.0;
    var qy = 0.0;
    var qz = 0.0;
    var qw = 1.0;
    final rot = rotations;
    if (rot != null) {
      final a4 = i0 * 4;
      if (i0 == i1 || alpha <= 0.0) {
        (qx, qy, qz, qw) = Quaternion3D.normalize(
          rot[a4],
          rot[a4 + 1],
          rot[a4 + 2],
          rot[a4 + 3],
        );
      } else {
        final b4 = i1 * 4;
        (qx, qy, qz, qw) = Quaternion3D.slerp(
          (rot[a4], rot[a4 + 1], rot[a4 + 2], rot[a4 + 3]),
          (rot[b4], rot[b4 + 1], rot[b4 + 2], rot[b4 + 3]),
          alpha,
        );
      }
    }

    var sx = 1.0;
    var sy = 1.0;
    var sz = 1.0;
    final sc = scales;
    if (sc != null) {
      final a3 = i0 * 3;
      if (i0 == i1 || alpha <= 0.0) {
        sx = sc[a3];
        sy = sc[a3 + 1];
        sz = sc[a3 + 2];
      } else {
        final b3 = i1 * 3;
        sx = sc[a3] + (sc[b3] - sc[a3]) * alpha;
        sy = sc[a3 + 1] + (sc[b3 + 1] - sc[a3 + 1]) * alpha;
        sz = sc[a3 + 2] + (sc[b3 + 2] - sc[a3 + 2]) * alpha;
      }
    }

    return (
      dx: dx,
      dy: dy,
      dz: dz,
      qx: qx,
      qy: qy,
      qz: qz,
      qw: qw,
      sx: sx,
      sy: sy,
      sz: sz,
    );
  }
}

/// Keyframed scalar weight track targeting a [MorphTarget3D] slot inside a
/// [MorphMeshWorkspace3D].
class MorphWeightTrack3D({
  required final int targetIndex,
  required final Float32List times,
  required final Float32List weights,
}) {
  this
    : assert(times.isNotEmpty, 'times must not be empty'),
      assert(
        weights.length == times.length,
        'weights length must equal times.length',
      );

  /// Samples scalar morph weight at time [t].
  double sample(double t) {
    final (i0, i1, alpha) = TransformTrack3D._locateSegment(times, t);
    if (i0 == i1 || alpha <= 0.0) {
      return weights[i0];
    }
    return weights[i0] + (weights[i1] - weights[i0]) * alpha;
  }
}

/// Reusable 3D skeletal, node-hierarchy, and morph-target animation clip with
/// compact binary `DA3D` serialization ([toBytes] / [AnimationClip3D.fromBytes]).
class AnimationClip3D({
  required final String name,
  required final double duration,
  final bool looping = true,
  final List<TransformTrack3D> tracks = const <TransformTrack3D>[],
  final List<MorphWeightTrack3D> morphTracks = const <MorphWeightTrack3D>[],
  final List<AnimationEvent3D> events = const <AnimationEvent3D>[],
}) {
  static const int _magic = 0x33414446; // 'FDA3' little-endian ('DA3D' v1)
  static const int _version = 1;

  /// Serializes this animation clip into a compact binary `DA3D` v1 buffer.
  Uint8List toBytes() {
    final builder = BytesBuilder(copy: false);

    void writeUint32(int v) {
      final bd = ByteData(4)..setUint32(0, v, Endian.little);
      builder.add(bd.buffer.asUint8List());
    }

    void writeFloat32(double v) {
      final bd = ByteData(4)..setFloat32(0, v, Endian.little);
      builder.add(bd.buffer.asUint8List());
    }

    void writeString(String s) {
      final utf = utf8.encode(s);
      writeUint32(utf.length);
      builder.add(utf);
    }

    void writeFloat32List(Float32List list) {
      final bd = ByteData(list.length * 4);
      for (var i = 0; i < list.length; i++) {
        bd.setFloat32(i * 4, list[i], Endian.little);
      }
      builder.add(bd.buffer.asUint8List());
    }

    writeUint32(_magic);
    writeUint32(_version);
    writeString(name);
    writeFloat32(duration);
    writeUint32(looping ? 1 : 0);

    writeUint32(tracks.length);
    for (final tr in tracks) {
      writeUint32(tr.targetIndex);
      writeString(tr.targetName);
      writeUint32(tr.times.length);
      final flags =
          (tr.translations != null ? 1 : 0) |
          (tr.rotations != null ? 2 : 0) |
          (tr.scales != null ? 4 : 0);
      writeUint32(flags);
      writeFloat32List(tr.times);
      if (tr.translations != null) {
        writeFloat32List(tr.translations!);
      }
      if (tr.rotations != null) {
        writeFloat32List(tr.rotations!);
      }
      if (tr.scales != null) {
        writeFloat32List(tr.scales!);
      }
    }

    writeUint32(morphTracks.length);
    for (final mt in morphTracks) {
      writeUint32(mt.targetIndex);
      writeUint32(mt.times.length);
      writeFloat32List(mt.times);
      writeFloat32List(mt.weights);
    }

    writeUint32(events.length);
    for (final ev in events) {
      writeFloat32(ev.time);
      writeString(ev.name);
    }

    return builder.toBytes();
  }

  /// Decodes a binary `DA3D` v1 buffer produced by [toBytes].
  factory AnimationClip3D.fromBytes(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    var offset = 0;

    int readUint32() {
      final v = bd.getUint32(offset, Endian.little);
      offset += 4;
      return v;
    }

    double readFloat32() {
      final v = bd.getFloat32(offset, Endian.little);
      offset += 4;
      return v;
    }

    String readString() {
      final len = readUint32();
      final s = utf8.decode(Uint8List.sublistView(bytes, offset, offset + len));
      offset += len;
      return s;
    }

    Float32List readFloat32List(int count) {
      final out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = bd.getFloat32(offset + i * 4, Endian.little);
      }
      offset += count * 4;
      return out;
    }

    final magic = readUint32();
    if (magic != _magic) {
      throw FormatException(
        'Invalid DA3D magic header: 0x${magic.toRadixString(16)}',
      );
    }
    final version = readUint32();
    if (version != _version) {
      throw FormatException('Unsupported DA3D version: $version');
    }

    final clipName = readString();
    final clipDuration = readFloat32();
    final clipLooping = readUint32() != 0;

    final trackCount = readUint32();
    final tracks = <TransformTrack3D>[];
    for (var i = 0; i < trackCount; i++) {
      final targetIndex = readUint32();
      final targetName = readString();
      final keyCount = readUint32();
      final flags = readUint32();
      final times = readFloat32List(keyCount);
      final translations = (flags & 1) != 0
          ? readFloat32List(keyCount * 3)
          : null;
      final rotations = (flags & 2) != 0 ? readFloat32List(keyCount * 4) : null;
      final scales = (flags & 4) != 0 ? readFloat32List(keyCount * 3) : null;
      tracks.add(
        TransformTrack3D(
          targetIndex: targetIndex,
          targetName: targetName,
          times: times,
          translations: translations,
          rotations: rotations,
          scales: scales,
        ),
      );
    }

    final morphCount = readUint32();
    final morphTracks = <MorphWeightTrack3D>[];
    for (var i = 0; i < morphCount; i++) {
      final targetIndex = readUint32();
      final keyCount = readUint32();
      final times = readFloat32List(keyCount);
      final weights = readFloat32List(keyCount);
      morphTracks.add(
        MorphWeightTrack3D(
          targetIndex: targetIndex,
          times: times,
          weights: weights,
        ),
      );
    }

    final eventCount = readUint32();
    final events = <AnimationEvent3D>[];
    for (var i = 0; i < eventCount; i++) {
      final evTime = readFloat32();
      final evName = readString();
      events.add(AnimationEvent3D(time: evTime, name: evName));
    }

    return AnimationClip3D(
      name: clipName,
      duration: clipDuration,
      looping: clipLooping,
      tracks: tracks,
      morphTracks: morphTracks,
      events: events,
    );
  }
}

/// Real-time 3D animation controller driving [SkinnedMeshWorkspace3D],
/// [Node3D] hierarchies, and [MorphMeshWorkspace3D] with smooth SLERP
/// cross-fading (`crossFadeTo`), bone-masked secondary layers (`setLayerClip`),
/// and frame-accurate [AnimationEvent3D] callbacks.
class AnimationMixer3D({
  this.skinnedWorkspace,
  this.morphWorkspace,
  this.rootNode,
  List<Node3D>? indexedNodes,
  this.onEvent,
}) {
  /// Optional skeletal skinning target.
  final SkinnedMeshWorkspace3D? skinnedWorkspace;

  /// Optional morph-target workspace driven by [MorphWeightTrack3D]s.
  final MorphMeshWorkspace3D? morphWorkspace;

  /// Optional root [Node3D] searched by `TransformTrack3D.targetName`.
  final Node3D? rootNode;

  final List<Node3D>? _indexedNodes = indexedNodes;

  /// Optional callback invoked whenever the primary clip crosses an
  /// [AnimationEvent3D].
  void Function(AnimationEvent3D event)? onEvent;

  AnimationClip3D? _currentClip;
  double _currentTime = 0.0;
  double _currentSpeed = 1.0;

  AnimationClip3D? _fadeFromClip;
  double _fadeFromTime = 0.0;
  double _fadeFromSpeed = 1.0;
  double _fadeDuration = 0.0;
  double _fadeElapsed = 0.0;

  AnimationClip3D? _layerClip;
  double _layerTime = 0.0;
  double _layerSpeed = 1.0;
  double _layerWeight = 0.0;
  Set<int>? _layerBoneMask;

  /// Currently playing primary clip (`null` if idle).
  AnimationClip3D? get currentClip => _currentClip;

  /// Playback cursor (in seconds) of [currentClip].
  double get currentTime => _currentTime;

  /// Whether a cross-fade transition is currently blending.
  bool get isCrossFading =>
      _fadeFromClip != null && _fadeElapsed < _fadeDuration;

  /// Starts playing [clip] immediately.
  void play(
    AnimationClip3D clip, {
    double speed = 1.0,
    bool restart = true,
  }) {
    if (!restart && identical(_currentClip, clip)) {
      _currentSpeed = speed;
      return;
    }
    _currentClip = clip;
    _currentTime = 0.0;
    _currentSpeed = speed;
    _fadeFromClip = null;
    _fadeDuration = 0.0;
    _fadeElapsed = 0.0;
    _applyAtCurrentState();
  }

  /// Smoothly cross-fades from the active pose/clip into [nextClip] over
  /// [duration] seconds using linear translation/scale blend and shortest-arc
  /// quaternion SLERP.
  void crossFadeTo(
    AnimationClip3D nextClip, {
    double duration = 0.25,
    double speed = 1.0,
  }) {
    if (_currentClip == null || duration <= 1e-5) {
      play(nextClip, speed: speed);
      return;
    }
    if (identical(_currentClip, nextClip)) {
      _currentSpeed = speed;
      return;
    }
    _fadeFromClip = _currentClip;
    _fadeFromTime = _currentTime;
    _fadeFromSpeed = _currentSpeed;
    _fadeDuration = duration;
    _fadeElapsed = 0.0;

    _currentClip = nextClip;
    _currentTime = 0.0;
    _currentSpeed = speed;
    _applyAtCurrentState();
  }

  /// Configures an optional secondary override/additive blend layer (for
  /// example an upper-body wave or aim clip restricted to [boneMask]).
  void setLayerClip(
    AnimationClip3D? clip, {
    double weight = 1.0,
    Set<int>? boneMask,
    double speed = 1.0,
  }) {
    _layerClip = clip;
    _layerTime = 0.0;
    _layerWeight = weight.clamp(0.0, 1.0);
    _layerBoneMask = boneMask;
    _layerSpeed = speed;
    if (_currentClip != null || clip != null) {
      _applyAtCurrentState();
    }
  }

  static double _advanceClipTime(
    AnimationClip3D clip,
    double prevTime,
    double delta, {
    void Function(AnimationEvent3D event)? eventSink,
  }) {
    final dur = math.max(1e-6, clip.duration);
    final rawNext = prevTime + delta;
    if (!clip.looping) {
      final next = rawNext.clamp(0.0, dur);
      if (eventSink != null && clip.events.isNotEmpty && delta > 0.0) {
        for (final ev in clip.events) {
          if (ev.time > prevTime && ev.time <= next) {
            eventSink(ev);
          }
        }
      }
      return next;
    }

    var next = rawNext % dur;
    if (next < 0.0) {
      next += dur;
    }
    if (eventSink != null && clip.events.isNotEmpty && delta > 0.0) {
      if (rawNext < dur) {
        for (final ev in clip.events) {
          if (ev.time > prevTime && ev.time <= next) {
            eventSink(ev);
          }
        }
      } else {
        for (final ev in clip.events) {
          if (ev.time > prevTime || ev.time <= next) {
            eventSink(ev);
          }
        }
      }
    }
    return next;
  }

  /// Advances playback by [dt] seconds and writes blended poses into attached
  /// workspaces / nodes.
  void update(double dt) {
    final primary = _currentClip;
    if (primary == null && _layerClip == null) {
      return;
    }

    if (primary != null && dt != 0.0) {
      _currentTime = _advanceClipTime(
        primary,
        _currentTime,
        dt * _currentSpeed,
        eventSink: onEvent,
      );
    }

    if (_fadeFromClip != null) {
      _fadeFromTime = _advanceClipTime(
        _fadeFromClip!,
        _fadeFromTime,
        dt * _fadeFromSpeed,
      );
      _fadeElapsed += dt.abs();
      if (_fadeElapsed >= _fadeDuration) {
        _fadeFromClip = null;
      }
    }

    if (_layerClip != null && dt != 0.0) {
      _layerTime = _advanceClipTime(
        _layerClip!,
        _layerTime,
        dt * _layerSpeed,
      );
    }

    _applyAtCurrentState();
  }

  TransformTrack3D? _findTrack(
    AnimationClip3D clip,
    int targetIndex,
    String targetName,
  ) {
    for (var i = 0; i < clip.tracks.length; i++) {
      final tr = clip.tracks[i];
      if (tr.targetIndex == targetIndex ||
          (targetName.isNotEmpty && tr.targetName == targetName)) {
        return tr;
      }
    }
    return null;
  }

  Node3D? _resolveNode(TransformTrack3D track) {
    final list = _indexedNodes;
    if (list != null &&
        track.targetIndex >= 0 &&
        track.targetIndex < list.length) {
      return list[track.targetIndex];
    }
    if (rootNode != null && track.targetName.isNotEmpty) {
      return rootNode!.findByName(track.targetName);
    }
    return null;
  }

  void _applyAtCurrentState() {
    final primary = _currentClip;
    final fromClip = _fadeFromClip;
    final fadeAlpha = (fromClip != null && _fadeDuration > 1e-6)
        ? (_fadeElapsed / _fadeDuration).clamp(0.0, 1.0)
        : 1.0;

    final skin = skinnedWorkspace;
    if (skin != null) {
      for (var b = 0; b < skin.bones.length; b++) {
        final boneName = skin.bones[b].name;
        final pTrack = primary != null
            ? _findTrack(primary, b, boneName)
            : null;
        final fTrack = fromClip != null
            ? _findTrack(fromClip, b, boneName)
            : null;
        final lTrack =
            (_layerClip != null &&
                _layerWeight > 0.0 &&
                (_layerBoneMask == null || _layerBoneMask!.contains(b)))
            ? _findTrack(_layerClip!, b, boneName)
            : null;

        if (pTrack == null && fTrack == null && lTrack == null) {
          continue;
        }

        var pose = pTrack != null
            ? pTrack.sample(_currentTime)
            : (
                dx: 0.0,
                dy: 0.0,
                dz: 0.0,
                qx: 0.0,
                qy: 0.0,
                qz: 0.0,
                qw: 1.0,
                sx: 1.0,
                sy: 1.0,
                sz: 1.0,
              );

        if (fromClip != null && fadeAlpha < 1.0) {
          final fp = fTrack != null
              ? fTrack.sample(_fadeFromTime)
              : (
                  dx: 0.0,
                  dy: 0.0,
                  dz: 0.0,
                  qx: 0.0,
                  qy: 0.0,
                  qz: 0.0,
                  qw: 1.0,
                  sx: 1.0,
                  sy: 1.0,
                  sz: 1.0,
                );
          final (qx, qy, qz, qw) = Quaternion3D.slerp(
            (fp.qx, fp.qy, fp.qz, fp.qw),
            (pose.qx, pose.qy, pose.qz, pose.qw),
            fadeAlpha,
          );
          pose = (
            dx: fp.dx + (pose.dx - fp.dx) * fadeAlpha,
            dy: fp.dy + (pose.dy - fp.dy) * fadeAlpha,
            dz: fp.dz + (pose.dz - fp.dz) * fadeAlpha,
            qx: qx,
            qy: qy,
            qz: qz,
            qw: qw,
            sx: fp.sx + (pose.sx - fp.sx) * fadeAlpha,
            sy: fp.sy + (pose.sy - fp.sy) * fadeAlpha,
            sz: fp.sz + (pose.sz - fp.sz) * fadeAlpha,
          );
        }

        if (lTrack != null) {
          final lp = lTrack.sample(_layerTime);
          final w = _layerWeight;
          final (qx, qy, qz, qw) = Quaternion3D.slerp(
            (pose.qx, pose.qy, pose.qz, pose.qw),
            (lp.qx, lp.qy, lp.qz, lp.qw),
            w,
          );
          pose = (
            dx: pose.dx + (lp.dx - pose.dx) * w,
            dy: pose.dy + (lp.dy - pose.dy) * w,
            dz: pose.dz + (lp.dz - pose.dz) * w,
            qx: qx,
            qy: qy,
            qz: qz,
            qw: qw,
            sx: pose.sx + (lp.sx - pose.sx) * w,
            sy: pose.sy + (lp.sy - pose.sy) * w,
            sz: pose.sz + (lp.sz - pose.sz) * w,
          );
        }

        skin.setBonePose(
          b,
          dx: pose.dx,
          dy: pose.dy,
          dz: pose.dz,
          qx: pose.qx,
          qy: pose.qy,
          qz: pose.qz,
          qw: pose.qw,
          sx: pose.sx,
          sy: pose.sy,
          sz: pose.sz,
        );
      }
    }

    if (primary != null && (rootNode != null || _indexedNodes != null)) {
      for (final pTrack in primary.tracks) {
        final node = _resolveNode(pTrack);
        if (node == null) {
          continue;
        }
        var pose = pTrack.sample(_currentTime);
        if (fromClip != null && fadeAlpha < 1.0) {
          final fTrack = _findTrack(
            fromClip,
            pTrack.targetIndex,
            pTrack.targetName,
          );
          if (fTrack != null) {
            final fp = fTrack.sample(_fadeFromTime);
            final (qx, qy, qz, qw) = Quaternion3D.slerp(
              (fp.qx, fp.qy, fp.qz, fp.qw),
              (pose.qx, pose.qy, pose.qz, pose.qw),
              fadeAlpha,
            );
            pose = (
              dx: fp.dx + (pose.dx - fp.dx) * fadeAlpha,
              dy: fp.dy + (pose.dy - fp.dy) * fadeAlpha,
              dz: fp.dz + (pose.dz - fp.dz) * fadeAlpha,
              qx: qx,
              qy: qy,
              qz: qz,
              qw: qw,
              sx: fp.sx + (pose.sx - fp.sx) * fadeAlpha,
              sy: fp.sy + (pose.sy - fp.sy) * fadeAlpha,
              sz: fp.sz + (pose.sz - fp.sz) * fadeAlpha,
            );
          }
        }
        if (pTrack.translations != null) {
          node
            ..localX = pose.dx
            ..localY = pose.dy
            ..localZ = pose.dz;
        }
        if (pTrack.scales != null) {
          node
            ..localScaleX = pose.sx
            ..localScaleY = pose.sy
            ..localScaleZ = pose.sz;
        }
        if (pTrack.rotations != null) {
          node.setLocalQuaternion(pose.qx, pose.qy, pose.qz, pose.qw);
        }
      }
      rootNode?.updateWorldTransforms();
    }

    final morph = morphWorkspace;
    if (morph != null && primary != null) {
      for (final mt in primary.morphTracks) {
        var w = mt.sample(_currentTime);
        if (fromClip != null && fadeAlpha < 1.0) {
          var prevW = 0.0;
          for (final fmt in fromClip.morphTracks) {
            if (fmt.targetIndex == mt.targetIndex) {
              prevW = fmt.sample(_fadeFromTime);
              break;
            }
          }
          w = prevW + (w - prevW) * fadeAlpha;
        }
        morph.setWeight(mt.targetIndex, w);
      }
    }
  }
}
