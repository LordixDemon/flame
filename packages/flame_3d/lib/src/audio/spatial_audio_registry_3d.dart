import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/src/audio/spatial_audio_3d.dart';
import 'package:flame_3d/src/audio/spatial_audio_mixer_3d.dart';
import 'package:meta/meta.dart';

/// The spatial audio components mounted in one [World3D].
///
/// Listeners, emitters and zones add themselves when they mount and remove
/// themselves when they are removed, so mixers and emitters find them without
/// walking the component tree. Not exported.
@internal
class SpatialAudioRegistry3D._() {
  /// The registry of [world], created on first use.
  factory SpatialAudioRegistry3D.of(World3D world) {
    return _byWorld[world] ??= SpatialAudioRegistry3D._();
  }

  static final Expando<SpatialAudioRegistry3D> _byWorld = Expando();

  /// The registry of [world], or `null` when nothing was registered in it.
  static SpatialAudioRegistry3D? maybeOf(World3D? world) {
    return world == null ? null : _byWorld[world];
  }

  /// Mounted listeners, in mount order.
  final List<SpatialAudioListener3D> listeners = [];

  /// Mounted emitters, in mount order.
  final List<SpatialAudioEmitter3D> emitters = [];

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

  /// Mounted mixers, told when an emitter leaves the world.
  final List<SpatialAudioMixer3D> mixers = [];

  /// The first mounted listener, or `null`.
  SpatialAudioListener3D? get firstListener =>
      listeners.isEmpty ? null : listeners.first;

  /// Removes [emitter] and tells every mixer of the world to forget it.
  void removeEmitter(SpatialAudioEmitter3D emitter) {
    emitters.remove(emitter);
    for (var i = 0; i < mixers.length; i++) {
      mixers[i].forgetEmitter(emitter);
    }
  }
}
