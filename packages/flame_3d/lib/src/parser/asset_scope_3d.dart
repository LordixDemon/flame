import 'package:flame_3d/model.dart' show Model;
import 'package:flame_3d/resources.dart' show Mesh, Resource, Surface, Texture;

/// Reference-counted GPU asset container for [Model]s, [Mesh]es, [Surface]s,
/// and [Texture]s.
///
/// Releasing the last reference to an asset (or calling [disposeAll]) calls
/// [Resource.dispose] on all owned [Surface] vertex/index buffers and
/// [Texture] handles (while preserving shared static singletons
/// [Texture.standard] and [Texture.empty]).
class AssetScope3D() {
  final Map<Object, int> _assetRefCounts = {};
  final Map<Resource<Object?>, int> _leafRefCounts = {};

  /// Number of top-level assets currently retained in this scope.
  int get retainedAssetCount => _assetRefCounts.length;

  /// Number of unique underlying GPU [Resource]s (`Surface`s and `Texture`s)
  /// currently tracked by this scope.
  int get trackedResourceCount => _leafRefCounts.length;

  /// Current reference count for [asset] (`0` if not retained).
  int refCountOf(Object asset) => _assetRefCounts[asset] ?? 0;

  /// Increments the reference count of [asset] (`Model`, `Mesh`, `Surface`,
  /// `Texture`, or arbitrary owner handle) and returns [asset].
  T retain<T extends Object>(T asset) {
    final prev = _assetRefCounts[asset] ?? 0;
    _assetRefCounts[asset] = prev + 1;
    if (prev == 0) {
      for (final res in _collectOwnedResources(asset)) {
        _leafRefCounts[res] = (_leafRefCounts[res] ?? 0) + 1;
      }
    }
    return asset;
  }

  /// Decrements the reference count of [asset]. When it reaches `0`, any owned
  /// [Surface]s and [Texture]s not shared with another retained asset are
  /// disposed via [Resource.dispose], and `true` is returned.
  bool release(Object asset) {
    final current = _assetRefCounts[asset];
    if (current == null || current <= 0) {
      return false;
    }
    if (current > 1) {
      _assetRefCounts[asset] = current - 1;
      return false;
    }
    _assetRefCounts.remove(asset);
    for (final res in _collectOwnedResources(asset)) {
      final leafCount = _leafRefCounts[res] ?? 0;
      if (leafCount <= 1) {
        _leafRefCounts.remove(res);
        res.dispose();
      } else {
        _leafRefCounts[res] = leafCount - 1;
      }
    }
    if (asset is Mesh) {
      asset.dispose();
    }
    return true;
  }

  /// Disposes every tracked [Surface], [Texture], and [Mesh] in this scope and
  /// resets all reference counts to `0`.
  void disposeAll() {
    for (final res in _leafRefCounts.keys) {
      res.dispose();
    }
    for (final asset in _assetRefCounts.keys) {
      if (asset is Mesh) {
        asset.dispose();
      } else if (asset is Model) {
        for (final node in asset.nodes.values) {
          node.mesh?.dispose();
        }
      }
    }
    _leafRefCounts.clear();
    _assetRefCounts.clear();
  }

  static Set<Resource<Object?>> _collectOwnedResources(Object asset) {
    final out = <Resource<Object?>>{};

    void addTexture(Texture? tex) {
      if (tex == null ||
          identical(tex, Texture.standard) ||
          identical(tex, Texture.empty)) {
        return;
      }
      out.add(tex);
    }

    void addSurface(Surface surface) {
      out.add(surface);
      surface.material.visitTextures(addTexture);
    }

    if (asset is Texture) {
      addTexture(asset);
    } else if (asset is Surface) {
      addSurface(asset);
    } else if (asset is Mesh) {
      for (final s in asset.surfaces) {
        addSurface(s);
      }
    } else if (asset is Model) {
      for (final node in asset.nodes.values) {
        final mesh = node.mesh;
        if (mesh != null) {
          for (final s in mesh.surfaces) {
            addSurface(s);
          }
        }
      }
    }
    return out;
  }
}
