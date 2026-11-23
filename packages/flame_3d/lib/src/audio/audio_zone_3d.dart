import 'dart:math' as math;

import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:meta/meta.dart';

/// Per-[World3D] registry of mounted [AudioZone3D] reverb volumes.
/// Not exported.
@internal
class AudioZoneWorldRegistry3D._() {
  /// Returns the zone registry for [world], creating it on first use.
  factory AudioZoneWorldRegistry3D.of(World3D world) {
    return _byWorld[world] ??= AudioZoneWorldRegistry3D._();
  }

  static final Expando<AudioZoneWorldRegistry3D> _byWorld = Expando();

  /// Returns the zone registry for [world], or `null` when none exists yet.
  static AudioZoneWorldRegistry3D? maybeOf(World3D? world) {
    return world == null ? null : _byWorld[world];
  }

  /// Mounted zones, in mount order.
  final List<AudioZone3D> zones = [];

  /// Monotonic counter bumped whenever [zones] changes.
  int zonesVersion = 0;

  /// Registers [zone] and bumps [zonesVersion].
  void addZone(AudioZone3D zone) {
    zones.add(zone);
    zonesVersion++;
  }

  /// Unregisters [zone] and bumps [zonesVersion].
  void removeZone(AudioZone3D zone) {
    if (zones.remove(zone)) {
      zonesVersion++;
    }
  }
}

/// Acoustic reverb impulse/algorithmic preset parameters blended across
/// [AudioZone3D] volumes by `SpatialAudioMixer3D`.
class const ReverbPreset3D({
  required final double wetMix,
  required final double decaySeconds,
  required final double preDelayMs,
  final String name = 'custom',
}) {
  /// Linearly interpolates between [a] and [b] by [t] in `[0, 1]`.
  factory ReverbPreset3D.lerp(
    ReverbPreset3D a,
    ReverbPreset3D b,
    double t,
  ) {
    final u = t.clamp(0.0, 1.0);
    return ReverbPreset3D(
      wetMix: a.wetMix + (b.wetMix - a.wetMix) * u,
      decaySeconds: a.decaySeconds + (b.decaySeconds - a.decaySeconds) * u,
      preDelayMs: a.preDelayMs + (b.preDelayMs - a.preDelayMs) * u,
      name: u < 0.5 ? a.name : b.name,
    );
  }

  /// Dry outdoor / anechoic baseline (`wetMix: 0`).
  static const ReverbPreset3D dry = ReverbPreset3D(
    wetMix: 0.0,
    decaySeconds: 0.2,
    preDelayMs: 0.0,
    name: 'dry',
  );

  /// Compact indoor room preset.
  static const ReverbPreset3D room = ReverbPreset3D(
    wetMix: 0.25,
    decaySeconds: 0.9,
    preDelayMs: 8.0,
    name: 'room',
  );

  /// Stone cavern / tunnel preset.
  static const ReverbPreset3D cave = ReverbPreset3D(
    wetMix: 0.6,
    decaySeconds: 2.8,
    preDelayMs: 24.0,
    name: 'cave',
  );

  /// Large reverberant hall / cathedral preset.
  static const ReverbPreset3D cathedral = ReverbPreset3D(
    wetMix: 0.78,
    decaySeconds: 4.5,
    preDelayMs: 42.0,
    name: 'cathedral',
  );
}

/// 3D spatial reverb zone (spherical [radius] or OBB [halfExtents]) with a
/// smooth outer [fadeDistance] feather margin.
///
/// A zone only describes reverb settings; `SpatialAudioMixer3D` blends the
/// zones' presets at the listener and hands the result to its backend, which
/// must apply it.
class AudioZone3D({
  required var ReverbPreset3D preset,
  var double radius = 8.0,
  Vector3? halfExtents,
  var double fadeDistance = 2.0,
  var bool enabled = true,
  int priority = 0,
  super.position,
  super.rotation,
  super.scale,
  super.children,
}) extends Component3D {
  this
    : assert(radius >= 0, 'radius must be non-negative'),
      assert(fadeDistance >= 0, 'fadeDistance must be non-negative');

  /// Order of this zone when overlapping zones are blended: zones with a
  /// higher [audioPriority] are applied later and win (`priority` in the
  /// constructor).
  ///
  /// This is not the component [priority], which orders the component among
  /// its siblings for updates and rendering.
  int audioPriority = priority;

  @override
  void onMount() {
    super.onMount();
    if (worldOrNull case final world?) {
      AudioZoneWorldRegistry3D.of(world).addZone(this);
    }
  }

  @override
  void onRemove() {
    AudioZoneWorldRegistry3D.maybeOf(worldOrNull)?.removeZone(this);
    super.onRemove();
  }

  /// Optional local box half-extents; when `null`, uses spherical [radius].
  final Vector3? halfExtents = halfExtents?.clone();

  final Matrix4 _invWorld = Matrix4.identity();
  final Vector3 _localPt = Vector3.zero();
  int _invWorldVer = -1;
  bool _invWorldValid = false;

  /// Computes spatial influence weight in `[0, 1]` at [worldPoint] (`1.0`
  /// inside the inner volume, tapering to `0.0` across [fadeDistance]).
  double weightAt(Vector3 worldPoint) {
    if (!enabled) {
      return 0.0;
    }
    final box = halfExtents;
    double signedDistOutside;
    if (box != null) {
      final worldMat = worldTransformMatrix;
      final worldVer = worldTransformVersion;
      if (worldVer != _invWorldVer) {
        _invWorldVer = worldVer;
        _invWorld.setFrom(worldMat);
        _invWorldValid = _invWorld.invert().abs() >= 1e-15;
      }
      if (!_invWorldValid) {
        return 0.0;
      }
      _localPt.setFrom(worldPoint);
      _invWorld.transform3(_localPt);
      final qx = math.max(0.0, _localPt.x.abs() - box.x);
      final qy = math.max(0.0, _localPt.y.abs() - box.y);
      final qz = math.max(0.0, _localPt.z.abs() - box.z);
      signedDistOutside = math.sqrt(qx * qx + qy * qy + qz * qz);
    } else {
      final s = worldTransformMatrix.storage;
      final dx = worldPoint.x - s[12];
      final dy = worldPoint.y - s[13];
      final dz = worldPoint.z - s[14];
      final distSq = dx * dx + dy * dy + dz * dz;
      final r = radius;
      if (distSq <= r * r) {
        return 1.0;
      }
      if (fadeDistance <= 1e-6) {
        return 0.0;
      }
      final maxR = r + fadeDistance;
      if (distSq >= maxR * maxR) {
        return 0.0;
      }
      signedDistOutside = math.sqrt(distSq) - r;
    }

    if (signedDistOutside <= 0.0) {
      return 1.0;
    }
    if (fadeDistance <= 1e-6 || signedDistOutside >= fadeDistance) {
      return 0.0;
    }
    final t = 1.0 - (signedDistOutside / fadeDistance);
    return t * t * (3.0 - 2.0 * t);
  }
}
