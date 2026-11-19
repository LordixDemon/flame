import 'dart:collection' show LinkedHashMap;
import 'dart:ui' show PixelFormat;

import 'package:flame_3d/resources.dart';

/// Ref-counted handle to a GPU [Resource] managed by [GpuResourceManager3D].
///
/// Calling [release] decrements the reference count of the cache entry the
/// lease was acquired from, once; subsequent calls on the same lease are safe
/// no-ops. A lease outlives its entry: when the entry was disposed since (by
/// [GpuResourceManager3D.disposeAll] or an eviction), releasing the lease does
/// nothing, even if a new entry was cached under the same [key] meanwhile.
class ResourceLease3D<T extends Resource<dynamic>>._(
  this._manager,
  this._entry,
  this.key,
  this.resource,
) {
  final GpuResourceManager3D _manager;
  final _ResourceEntry _entry;

  /// Cache key under which [resource] is tracked.
  final String key;

  /// Underlying GPU [Resource] (`Texture`, `Surface`, `Mesh`, etc.).
  final T resource;

  bool _released = false;

  /// Whether [release] has already been called on this lease.
  bool get isReleased => _released;

  /// Releases this lease's reference on [key].
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _manager._releaseEntry(_entry);
  }
}

/// Diagnostic record for one un-released entry in a [ResourceLeakReport3D].
class const ResourceLeakEntry3D({
  required final String key,
  required final Type resourceType,
  required final int refCount,
  required final int estimatedBytes,
  required final bool pinned,
});

/// Snapshot of active un-released GPU resources returned by
/// [GpuResourceManager3D.auditLeaks].
class ResourceLeakReport3D(final List<ResourceLeakEntry3D> entries) {
  /// Whether at least one resource still has `refCount > 0`.
  bool get hasLeaks => entries.isNotEmpty;

  /// Total estimated VRAM bytes across all leaked entries.
  int get totalLeakedBytes =>
      entries.fold(0, (sum, entry) => sum + entry.estimatedBytes);

  /// Keys of all leaked entries.
  List<String> get leakedKeys => [for (final entry in entries) entry.key];
}

/// Registry of GPU context-loss recovery hooks for recreating GPU buffers,
/// textures, and procedural targets after mobile backgrounding or WebGPU
/// device loss.
class GpuDeviceLossRecovery3D() {
  final LinkedHashMap<String, _RecoveryTask> _tasks = LinkedHashMap();
  int _recoveryCount = 0;

  /// Number of full recovery passes executed via [recoverAll].
  int get recoveryCount => _recoveryCount;

  /// Number of registered recovery hooks.
  int get registeredCount => _tasks.length;

  /// Registers a general rebuild callback under [id].
  void registerCallback(String id, void Function() onRecover) {
    _tasks[id] = _CallbackRecoveryTask(onRecover);
  }

  /// Registers a [Resource] (`Texture`, `Surface`, `Mesh`) under [id] so
  /// [markResourcesLost] and [recoverAll] invalidate and recreate its GPU
  /// handle (and invoke optional [onRebuild]).
  void registerResource<T extends Resource<dynamic>>(
    String id,
    T resource, {
    void Function(T resource)? onRebuild,
    bool eagerRecreate = true,
  }) {
    _tasks[id] = _ResourceRecoveryTask<T>(
      resource,
      onRebuild: onRebuild,
      eagerRecreate: eagerRecreate,
    );
  }

  /// Unregisters the recovery hook under [id], returning `true` if present.
  bool unregister(String id) => _tasks.remove(id) != null;

  /// Clears all registered recovery hooks.
  void clear() => _tasks.clear();

  /// Marks all registered [Resource]s as lost (`dispose()`) without recreating
  /// them yet.
  void markResourcesLost() {
    for (final task in _tasks.values) {
      task.markLost();
    }
  }

  /// Invalidates stale GPU handles and executes all registered rebuild hooks in
  /// deterministic registration order, returning the number of recovered items.
  int recoverAll({bool eagerRecreate = true}) {
    var count = 0;
    for (final task in _tasks.values) {
      task.recover(eagerRecreate: eagerRecreate);
      count++;
    }
    _recoveryCount++;
    return count;
  }
}

sealed class _RecoveryTask() {
  void markLost();
  void recover({required bool eagerRecreate});
}

final class _CallbackRecoveryTask(final void Function() _callback)
    extends _RecoveryTask {
  @override
  void markLost() {}

  @override
  void recover({required bool eagerRecreate}) {
    _callback();
  }
}

final class _ResourceRecoveryTask<T extends Resource<dynamic>>(
  final T _resource, {
  final void Function(T resource)? onRebuild,
  final bool eagerRecreate = true,
}) extends _RecoveryTask {
  @override
  void markLost() {
    GpuResourceManager3D._disposeResourceTree(_resource);
  }

  @override
  void recover({required bool eagerRecreate}) {
    GpuResourceManager3D._disposeResourceTree(_resource);
    onRebuild?.call(_resource);
    if (eagerRecreate && this.eagerRecreate) {
      GpuResourceManager3D._touchResourceTree(_resource);
    }
  }
}

/// Ref-counted GPU [Resource] pool with an LRU zero-ref cache, deterministic
/// VRAM byte budgeting, leak auditing, and [GpuDeviceLossRecovery3D].
class GpuResourceManager3D({
  int maxVramBytes = 256 * 1024 * 1024,
  GpuDeviceLossRecovery3D? deviceLossRecovery,
}) {
  this {
    if (maxVramBytes < 0) {
      throw ArgumentError.value(
        maxVramBytes,
        'maxVramBytes',
        'Must be non-negative',
      );
    }
    _maxVramBytes = maxVramBytes;
  }

  int _maxVramBytes = 256 * 1024 * 1024;

  /// Device-loss recovery registry associated with this manager.
  final GpuDeviceLossRecovery3D deviceLossRecovery =
      deviceLossRecovery ?? GpuDeviceLossRecovery3D();

  final Map<String, _ResourceEntry> _entries = {};

  /// Zero-ref entries in insertion/access order: oldest (LRU) first, newest
  /// (MRU) last. `LinkedHashMap` removes and re-inserts in `O(1)`.
  final LinkedHashMap<String, _ResourceEntry> _zeroRefLru = LinkedHashMap();

  int _estimatedTotalBytes = 0;
  int _evictionCount = 0;

  /// Maximum VRAM budget in bytes before zero-ref LRU entries are evicted.
  int get maxVramBytes => _maxVramBytes;
  set maxVramBytes(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'maxVramBytes', 'Must be non-negative');
    }
    _maxVramBytes = value;
    if (_estimatedTotalBytes > _maxVramBytes) {
      trimToBudget();
    }
  }

  /// Total estimated VRAM bytes across all cached entries (active + zero-ref).
  int get estimatedTotalBytes => _estimatedTotalBytes;

  /// Estimated VRAM bytes held by active (`refCount > 0`) or `pinned` entries.
  int get activeBytes {
    var sum = 0;
    for (final entry in _entries.values) {
      if (entry.refCount > 0 || entry.pinned) {
        sum += entry.estimatedBytes;
      }
    }
    return sum;
  }

  /// Estimated VRAM bytes held by evictable zero-ref unpinned entries.
  int get unreferencedBytes => _estimatedTotalBytes - activeBytes;

  /// Total number of cached entries (active + zero-ref).
  int get entryCount => _entries.length;

  /// Number of zero-ref entries currently waiting in the LRU queue.
  int get lruCount => _zeroRefLru.length;

  /// Total number of resources evicted and disposed by budget trimming or
  /// [purgeUnreferenced].
  int get evictionCount => _evictionCount;

  /// Whether [key] is currently cached (either active or in the zero-ref LRU).
  bool containsKey(String key) => _entries.containsKey(key);

  /// Current reference count of [key] (`0` when unreferenced or absent).
  int refCountOf(String key) => _entries[key]?.refCount ?? 0;

  /// Whether [key] is pinned against LRU eviction.
  bool isPinned(String key) => _entries[key]?.pinned ?? false;

  /// Pins or unpins [key] so zero-ref trimming never disposes it while pinned.
  void setPinned(String key, {required bool pinned}) {
    final entry = _entries[key];
    if (entry == null) {
      throw StateError('Unknown GPU resource key "$key".');
    }
    entry.pinned = pinned;
    if (!pinned &&
        entry.refCount == 0 &&
        _estimatedTotalBytes > _maxVramBytes) {
      trimToBudget();
    }
  }

  /// Returns the cached resource under [key] without changing its ref count, or
  /// `null` if absent.
  T? peek<T extends Resource<dynamic>>(String key) {
    final res = _entries[key]?.resource;
    return res is T ? res : null;
  }

  /// Acquires a ref-counted [ResourceLease3D] for [key], creating the resource
  /// via [create] when not already cached.
  ///
  /// When [estimatedTotalBytes] exceeds [maxVramBytes], least-recently-used
  /// zero-ref unpinned resources are automatically evicted via `.dispose()`.
  ResourceLease3D<T> acquire<T extends Resource<dynamic>>(
    String key,
    T Function() create, {
    int? estimatedBytes,
    bool pinned = false,
  }) {
    final existing = _entries[key];
    if (existing != null) {
      final res = existing.resource;
      if (res is! T) {
        throw StateError(
          'GPU resource key "$key" already holds a different resource type.',
        );
      }
      _zeroRefLru.remove(key);
      existing.refCount++;
      if (pinned) {
        existing.pinned = true;
      }
      if (estimatedBytes != null && estimatedBytes != existing.estimatedBytes) {
        _estimatedTotalBytes += estimatedBytes - existing.estimatedBytes;
        existing.estimatedBytes = estimatedBytes;
      }
      if (_estimatedTotalBytes > _maxVramBytes) {
        trimToBudget();
      }
      return ResourceLease3D<T>._(this, existing, key, res);
    }

    final created = create();
    final bytes = mathMaxZero(estimatedBytes ?? estimateBytes(created));
    final entry = _ResourceEntry(
      key: key,
      resource: created,
      estimatedBytes: bytes,
      refCount: 1,
      pinned: pinned,
    );
    _entries[key] = entry;
    _estimatedTotalBytes += bytes;
    if (_estimatedTotalBytes > _maxVramBytes) {
      trimToBudget();
    }
    return ResourceLease3D<T>._(this, entry, key, created);
  }

  /// Decrements the reference count of [key] by `1`.
  ///
  /// When the reference count reaches `0`, the resource enters the LRU cache
  /// and becomes eligible for eviction (unless `pinned`).
  ///
  /// This releases a reference by key, whoever holds it; release the
  /// [ResourceLease3D] returned by [acquire] instead, which releases its own
  /// reference only.
  @Deprecated(
    'Release the ResourceLease3D returned by acquire: a release by key can '
    'drop a reference another lease holds.',
  )
  void release(String key) {
    final entry = _entries[key];
    if (entry == null) {
      throw StateError('Cannot release unknown GPU resource key "$key".');
    }
    _releaseEntry(entry);
  }

  void _releaseEntry(_ResourceEntry entry) {
    final key = entry.key;
    if (!identical(_entries[key], entry)) {
      // The entry was disposed (and maybe replaced) since: nothing to do.
      return;
    }
    if (entry.refCount <= 0) {
      throw StateError('GPU resource "$key" already has refCount 0.');
    }
    entry.refCount--;
    if (entry.refCount == 0) {
      _zeroRefLru
        ..remove(key)
        ..[key] = entry;
      if (_estimatedTotalBytes > _maxVramBytes) {
        trimToBudget();
      }
    }
  }

  /// Evicts least-recently-used zero-ref unpinned entries until
  /// [estimatedTotalBytes] is at most [targetBytes] (defaults to
  /// [maxVramBytes]), returning the number of evicted resources.
  int trimToBudget([int? targetBytes]) {
    final limit = targetBytes ?? _maxVramBytes;
    if (_estimatedTotalBytes <= limit || _zeroRefLru.isEmpty) {
      return 0;
    }
    final candidates = List<String>.of(_zeroRefLru.keys);
    var evicted = 0;
    for (final key in candidates) {
      if (_estimatedTotalBytes <= limit) {
        break;
      }
      final entry = _zeroRefLru[key];
      if (entry == null || entry.refCount > 0 || entry.pinned) {
        continue;
      }
      _evictEntry(entry);
      evicted++;
    }
    return evicted;
  }

  /// Disposes and removes all zero-ref unpinned resources immediately,
  /// returning the number of evicted resources.
  int purgeUnreferenced() => trimToBudget(0);

  /// Audits all currently tracked entries with `refCount > 0`, returning a
  /// [ResourceLeakReport3D] of un-released keys and byte sizes.
  ResourceLeakReport3D auditLeaks({bool includePinned = true}) {
    final leaks = <ResourceLeakEntry3D>[];
    for (final entry in _entries.values) {
      if (entry.refCount > 0 && (includePinned || !entry.pinned)) {
        leaks.add(
          ResourceLeakEntry3D(
            key: entry.key,
            resourceType: entry.resource.runtimeType,
            refCount: entry.refCount,
            estimatedBytes: entry.estimatedBytes,
            pinned: entry.pinned,
          ),
        );
      }
    }
    return ResourceLeakReport3D(List.unmodifiable(leaks));
  }

  /// Invalidates all cached GPU handles after a mobile/WebGPU context loss,
  /// runs [deviceLossRecovery] hooks, and (when [eagerRecreate] is `true`)
  /// recreates GPU handles for active or pinned resources.
  int recoverAfterDeviceLoss({bool eagerRecreate = true}) {
    for (final entry in _entries.values) {
      _disposeResourceTree(entry.resource);
    }
    var count = deviceLossRecovery.recoverAll(eagerRecreate: eagerRecreate);
    if (eagerRecreate) {
      for (final entry in _entries.values) {
        if (entry.refCount > 0 || entry.pinned) {
          _touchResourceTree(entry.resource);
          count++;
        }
      }
    }
    return count;
  }

  /// Disposes every cached resource (including pinned and active entries) and
  /// resets this manager.
  void disposeAll() {
    for (final entry in _entries.values) {
      _disposeResourceTree(entry.resource);
    }
    _entries.clear();
    _zeroRefLru.clear();
    _estimatedTotalBytes = 0;
  }

  void _evictEntry(_ResourceEntry entry) {
    _zeroRefLru.remove(entry.key);
    _entries.remove(entry.key);
    _estimatedTotalBytes = mathMaxZero(
      _estimatedTotalBytes - entry.estimatedBytes,
    );
    _disposeResourceTree(entry.resource);
    _evictionCount++;
  }

  /// Estimates the GPU memory footprint of [resource] in bytes.
  static int estimateBytes(Resource<dynamic> resource) {
    if (resource is Texture) {
      final bpp = switch (resource.format) {
        PixelFormat.rgbaFloat32 => 16,
        PixelFormat.rgba8888 || PixelFormat.bgra8888 => 4,
        _ => 4,
      };
      final base = resource.width * resource.height * bpp;
      return resource.mipmaps ? (base * 4) ~/ 3 : base;
    }
    if (resource is Surface) {
      return resource.verticesBytes + resource.indicesBytes;
    }
    if (resource is Mesh) {
      var sum = 0;
      for (final surface in resource.surfaces) {
        sum += surface.verticesBytes + surface.indicesBytes;
      }
      return sum;
    }
    return 0;
  }

  static void _disposeResourceTree(Resource<dynamic> resource) {
    if (resource is Mesh) {
      for (final surface in resource.surfaces) {
        surface.dispose();
      }
    }
    resource.dispose();
  }

  static void _touchResourceTree(Resource<dynamic> resource) {
    if (resource is Mesh) {
      for (final surface in resource.surfaces) {
        surface.resource;
      }
      return;
    }
    resource.resource;
  }

  static int mathMaxZero(int v) => v < 0 ? 0 : v;
}

class _ResourceEntry({
  required final String key,
  required final Resource<dynamic> resource,
  required var int estimatedBytes,
  required var int refCount,
  required var bool pinned,
});
