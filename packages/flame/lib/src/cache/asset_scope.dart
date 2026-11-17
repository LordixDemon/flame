import 'dart:ui' show Image;

import 'package:flame/src/cache/images.dart';
import 'package:flutter/foundation.dart';

/// Priority-tagged image entry inside an [AssetScope].
class const ScopedAssetEntry({
  required this.path,
  this.key,
  this.package,
  this.priority = 0,
  this.generator,
}) {
  /// Asset path or logical identifier.
  final String path;

  /// Optional explicit key in [Images] (defaults to resolved [path]).
  final String? key;

  /// Optional Flutter package owning [path].
  final String? package;

  /// Higher priority entries load first during [AssetScope.preload].
  final int priority;

  /// Optional procedural/custom async [Image] factory used instead of bundle IO.
  final Future<Image> Function()? generator;

  /// Resolved cache key inside [Images].
  String get resolvedKey => key ?? Images.resolvePath(path, package);
}

/// Reference-counted scene asset scope built over [Images], exposing live
/// `0.0 .. 1.0` loading progress for loading screens and safely releasing
/// shared vs scene-exclusive GPU textures when the scene exits.
class AssetScope({
  required this.name,
  required this.images,
  Iterable<ScopedAssetEntry> entries = const [],
}) {
  /// Human-readable scope name (e.g. `'menu'`, `'level_01'`).
  final String name;

  /// Backing [Images] cache.
  final Images images;

  final List<ScopedAssetEntry> _entries = List<ScopedAssetEntry>.of(entries);
  final Map<String, Image> _retained = <String, Image>{};
  final List<void Function()> _customDisposers = <void Function()>[];
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);

  bool _isLoaded = false;
  bool _isDisposed = false;

  /// Reactive `0.0 .. 1.0` preload progress suitable for loading-screen bars.
  ValueListenable<double> get progressListenable => _progress;

  /// Current preload completion ratio in `[0.0, 1.0]`.
  double get progress => _progress.value;

  /// Whether [preload] has completed without disposal.
  bool get isLoaded => _isLoaded && !_isDisposed;

  /// Whether [dispose] has been called on this scope.
  bool get isDisposed => _isDisposed;

  /// Keys currently retained by this scope.
  Iterable<String> get retainedKeys => _retained.keys;

  /// Registers an additional [ScopedAssetEntry] prior to [preload].
  void addAsset(
    String path, {
    String? key,
    String? package,
    int priority = 0,
    Future<Image> Function()? generator,
  }) {
    _entries.add(
      ScopedAssetEntry(
        path: path,
        key: key,
        package: package,
        priority: priority,
        generator: generator,
      ),
    );
  }

  /// Registers an arbitrary disposable resource (such as a `FragmentShader`,
  /// `DynamicSpriteAtlas`, or `MipChainImage`) tied to this scope's lifetime.
  void ownDisposable(void Function() disposer) {
    if (_isDisposed) {
      disposer();
      return;
    }
    _customDisposers.add(disposer);
  }

  /// Loads and retains all declared entries in descending `priority` order,
  /// updating [progressListenable] as each asset resolves (`concurrency`
  /// controls parallel decode workers).
  Future<void> preload({int concurrency = 4}) async {
    if (_isDisposed) {
      throw StateError('Cannot preload disposed AssetScope "$name"');
    }
    if (_entries.isEmpty) {
      _progress.value = 1.0;
      _isLoaded = true;
      return;
    }

    final sorted = List<ScopedAssetEntry>.of(_entries)
      ..sort((a, b) => b.priority.compareTo(a.priority));

    _progress.value = 0.0;
    var completed = 0;
    var cursor = 0;
    final total = sorted.length;
    final workers = concurrency.clamp(1, total);

    Future<void> runWorker() async {
      while (!_isDisposed) {
        final idx = cursor++;
        if (idx >= total) {
          return;
        }
        final spec = sorted[idx];
        final resolvedKey = spec.resolvedKey;
        // An entry that this scope already holds (a repeated preload, or two
        // entries with the same key) is not fetched again.
        if (!_retained.containsKey(resolvedKey)) {
          final img = await _fetch(spec, resolvedKey);
          if (_isDisposed) {
            return;
          }
          images.retain(img);
          if (_retained.containsKey(resolvedKey)) {
            // Another worker loaded the same key in the meantime and the
            // scope holds it already: one hold per key is enough.
            images.release(img);
          } else {
            _retained[resolvedKey] = img;
          }
        }
        completed++;
        _progress.value = completed / total;
      }
    }

    await Future.wait(List<Future<void>>.generate(workers, (_) => runWorker()));
    if (!_isDisposed) {
      _progress.value = 1.0;
      _isLoaded = true;
    }
  }

  /// Loads the image of [spec] and returns it once it is an image that
  /// [images] still holds.
  ///
  /// The cache can drop an image between the moment a load completes and the
  /// moment this scope retains it (an explicit `Images.clear`, or a budget
  /// eviction), in which case the image is loaded again instead of keeping a
  /// disposed one.
  Future<Image> _fetch(ScopedAssetEntry spec, String resolvedKey) async {
    const maxAttempts = 3;
    for (var attempt = 1; ; attempt++) {
      final img = spec.generator != null
          ? await images.fetchOrGenerate(resolvedKey, spec.generator!)
          : await images.load(
              spec.path,
              key: spec.key,
              package: spec.package,
            );
      if (_isDisposed ||
          identical(Images.ownerOf(img), images) ||
          attempt == maxAttempts) {
        return img;
      }
    }
  }

  /// Retrieves a retained [Image] by its resolved key.
  Image getImage(String key) {
    final img = _retained[key];
    if (img != null) {
      return img;
    }
    return images.fromCache(key);
  }

  /// Releases all retained images and owned disposables. When
  /// [evictZeroRefImmediately] is `true`, images that nothing else uses are
  /// immediately disposed from [images] with `Images.clearIfUnretained`,
  /// freeing VRAM. Returns the freed image bytes.
  ///
  /// An image is kept when something else still needs it: another
  /// [AssetScope] or a mounted component retains it, another scope is
  /// preloading it right now, or it was loaded within `Images.gracePeriod` by
  /// a component that has not been mounted yet. Such an image stays in
  /// [images] under the regular eviction rules.
  int dispose({bool evictZeroRefImmediately = true}) {
    if (_isDisposed) {
      return 0;
    }
    _isDisposed = true;
    _isLoaded = false;

    for (var i = _customDisposers.length - 1; i >= 0; i--) {
      _customDisposers[i]();
    }
    _customDisposers.clear();

    var freedBytes = 0;
    for (final entry in _retained.entries) {
      images.release(entry.value);
      if (evictZeroRefImmediately) {
        freedBytes += images.clearIfUnretained(entry.key);
      }
    }
    _retained.clear();
    _progress.dispose();
    return freedBytes;
  }
}
