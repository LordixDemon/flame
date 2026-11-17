import 'dart:collection';
import 'dart:ui';

/// A texture handed out by a [SharedParticleTextureCache].
///
/// The [image] stays valid for as long as at least one owner holds the
/// texture, whatever happens to the cache in the meantime.
final class SharedParticleTexture._(
  /// The shared GPU texture.
  final Image image,
) {
  int _owners = 0;
  bool _cached = true;
  bool _disposed = false;

  /// Whether [image] has been disposed. This only happens once no owner holds
  /// the texture anymore.
  bool get isDisposed => _disposed;

  void _dispose() {
    if (!_disposed) {
      _disposed = true;
      image.dispose();
    }
  }
}

/// A bounded, reference-counted cache of procedural particle textures shared
/// between renderer instances.
///
/// A texture is only ever disposed when nobody uses it: evicting it from the
/// cache or clearing the cache merely stops handing it out to new owners, and
/// the texture is disposed when its last owner releases it. An owner that is
/// garbage collected without releasing its texture is released automatically.
class SharedParticleTextureCache<K>({
  /// The number of textures kept for reuse. Textures that are in use never
  /// count as evictable, so the cache can temporarily hold more than this.
  required final int capacity,
}) {
  final LinkedHashMap<K, SharedParticleTexture> _entries = LinkedHashMap();
  late final Finalizer<SharedParticleTexture> _finalizer = Finalizer(_release);

  /// The number of textures currently handed out or kept for reuse.
  int get size => _entries.length;

  /// Returns the texture stored under [key], rasterizing it with [create]
  /// when there is none, and registers [owner] as one of its users.
  ///
  /// The owner gives the texture back with [release]; if it is garbage
  /// collected before that, the texture is given back on its behalf.
  SharedParticleTexture acquire(
    K key,
    Object owner,
    Image Function() create,
  ) {
    var entry = _entries[key];
    if (entry == null) {
      entry = SharedParticleTexture._(create());
      _entries[key] = entry;
    }
    entry._owners++;
    _finalizer.attach(owner, entry, detach: owner);
    _trim();
    return entry;
  }

  /// Gives back a [texture] that [owner] obtained from [acquire].
  void release(SharedParticleTexture texture, Object owner) {
    _finalizer.detach(owner);
    _release(texture);
  }

  /// Forgets every texture. Unused textures are disposed right away; textures
  /// that are still in use stay valid and are disposed when their last owner
  /// releases them.
  void clear() {
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    for (final entry in entries) {
      entry._cached = false;
      if (entry._owners == 0) {
        entry._dispose();
      }
    }
  }

  void _release(SharedParticleTexture texture) {
    if (texture._owners > 0) {
      texture._owners--;
    }
    if (texture._owners > 0) {
      return;
    }
    if (texture._cached) {
      _trim();
    } else {
      texture._dispose();
    }
  }

  /// Disposes the oldest unused textures while the cache is over capacity.
  void _trim() {
    while (_entries.length > capacity) {
      SharedParticleTexture? unused;
      K? unusedKey;
      for (final entry in _entries.entries) {
        if (entry.value._owners == 0) {
          unused = entry.value;
          unusedKey = entry.key;
          break;
        }
      }
      if (unused == null) {
        return;
      }
      _entries.remove(unusedKey);
      unused
        .._cached = false
        .._dispose();
    }
  }
}
