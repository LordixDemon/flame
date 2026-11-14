import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flame/collisions.dart';
import 'package:flame/geometry.dart';

class Sweep<T extends Hitbox<T>>({List<T>? items}) extends Broadphase<T> {
  @override
  final List<T> items = items ?? [];

  final List<T> _activeItems = <T>[];
  final List<T> _passiveItems = <T>[];
  final List<T> _inactiveItems = <T>[];

  final List<T> _openActive = <T>[];
  final List<T> _openPassive = <T>[];
  final ProspectPool<T> _prospectPool = ProspectPool<T>();

  bool _bucketsDirty = true;
  int _passiveSortCount = 0;

  /// Number of times the static (`CollisionType.passive`) bucket had to be
  /// sorted because membership changed or a passive hitbox moved across a
  /// neighbor's `min.x`. Remains unchanged on calm ticks when static geometry
  /// stays stationary.
  int get passiveSortCount => _passiveSortCount;

  @override
  void add(T item) {
    items.add(item);
    _bucketsDirty = true;
  }

  @override
  void remove(T item) {
    items.remove(item);
    _bucketsDirty = true;
  }

  bool _needsBucketRebuild() {
    if (_bucketsDirty) {
      return true;
    }
    final tracked =
        _activeItems.length + _passiveItems.length + _inactiveItems.length;
    if (tracked != items.length) {
      return true;
    }
    for (var i = 0; i < _activeItems.length; i++) {
      if (_activeItems[i].collisionType != CollisionType.active) {
        return true;
      }
    }
    for (var i = 0; i < _passiveItems.length; i++) {
      if (_passiveItems[i].collisionType != CollisionType.passive) {
        return true;
      }
    }
    for (var i = 0; i < _inactiveItems.length; i++) {
      if (_inactiveItems[i].collisionType != CollisionType.inactive) {
        return true;
      }
    }
    return false;
  }

  static bool _isSortedByMinX<H extends Hitbox<H>>(List<H> list) {
    final len = list.length;
    if (len <= 1) {
      return true;
    }
    var prev = list[0].aabb.min.x;
    for (var i = 1; i < len; i++) {
      final cur = list[i].aabb.min.x;
      if (!(cur >= prev)) {
        return false;
      }
      prev = cur;
    }
    return true;
  }

  void _syncBucketsAndSort() {
    if (_needsBucketRebuild()) {
      _activeItems.clear();
      _passiveItems.clear();
      _inactiveItems.clear();
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        switch (item.collisionType) {
          case CollisionType.active:
            _activeItems.add(item);
          case CollisionType.passive:
            _passiveItems.add(item);
          case CollisionType.inactive:
            _inactiveItems.add(item);
        }
      }
      _bucketsDirty = false;
      if (_activeItems.length > 1) {
        insertionSort(_activeItems, compare: _compareMinX);
      }
      if (_passiveItems.length > 1) {
        insertionSort(_passiveItems, compare: _compareMinX);
        _passiveSortCount++;
      }
      if (_inactiveItems.length > 1) {
        insertionSort(_inactiveItems, compare: _compareMinX);
      }
      return;
    }

    // Active hitboxes move frequently: insertion sort is O(A) on nearly-sorted
    // active entities.
    if (_activeItems.length > 1) {
      insertionSort(_activeItems, compare: _compareMinX);
    }

    // Passive hitboxes represent static walls/tiles/triggers: skip sorting
    // completely when ascending min.x order still holds.
    if (!_isSortedByMinX(_passiveItems)) {
      insertionSort(_passiveItems, compare: _compareMinX);
      _passiveSortCount++;
    }

    if (!_isSortedByMinX(_inactiveItems)) {
      insertionSort(_inactiveItems, compare: _compareMinX);
    }
  }

  @override
  void update() {
    _syncBucketsAndSort();
  }

  static int _compareMinX(Hitbox<dynamic> a, Hitbox<dynamic> b) =>
      a.aabb.min.x.compareTo(b.aabb.min.x);

  @override
  Iterable<CollisionProspect<T>> query() {
    if (_bucketsDirty ||
        _activeItems.length + _passiveItems.length + _inactiveItems.length !=
            items.length) {
      _syncBucketsAndSort();
    }

    _openActive.clear();
    _openPassive.clear();
    _prospectPool.reset();

    final nA = _activeItems.length;
    if (nA == 0) {
      return _prospectPool;
    }
    final nP = _passiveItems.length;

    var ia = 0;
    var ip = 0;

    while (ia < nA || ip < nP) {
      final takeActive =
          ip >= nP ||
          (ia < nA &&
              _activeItems[ia].aabb.min.x <= _passiveItems[ip].aabb.min.x);
      if (takeActive) {
        final activeItem = _activeItems[ia++];
        final aMin = activeItem.aabb.min.x;

        for (var i = _openActive.length - 1; i >= 0; i--) {
          final other = _openActive[i];
          if (other.aabb.max.x >= aMin) {
            if (activeItem.canCollideWithMask(other)) {
              _prospectPool.acquire(activeItem, other);
            }
          } else {
            _openActive[i] = _openActive.last;
            _openActive.removeLast();
          }
        }

        for (var i = _openPassive.length - 1; i >= 0; i--) {
          final passiveOther = _openPassive[i];
          if (passiveOther.aabb.max.x >= aMin) {
            if (activeItem.canCollideWithMask(passiveOther)) {
              _prospectPool.acquire(activeItem, passiveOther);
            }
          } else {
            _openPassive[i] = _openPassive.last;
            _openPassive.removeLast();
          }
        }

        _openActive.add(activeItem);
      } else {
        if (_openActive.isEmpty && ia >= nA) {
          break;
        }
        final passiveItem = _passiveItems[ip++];
        final pMin = passiveItem.aabb.min.x;

        if (_openActive.isNotEmpty) {
          for (var i = _openActive.length - 1; i >= 0; i--) {
            final activeOther = _openActive[i];
            if (activeOther.aabb.max.x >= pMin) {
              if (passiveItem.canCollideWithMask(activeOther)) {
                _prospectPool.acquire(passiveItem, activeOther);
              }
            } else {
              _openActive[i] = _openActive.last;
              _openActive.removeLast();
            }
          }
        }

        if (ia < nA && passiveItem.aabb.max.x >= _activeItems[ia].aabb.min.x) {
          _openPassive.add(passiveItem);
        }
      }
    }

    return _prospectPool;
  }

  @override
  void queryRayCandidates(Ray2 ray, double maxDistance, List<T> out) {
    if (maxDistance.isNaN || maxDistance < 0) {
      return;
    }
    _syncBucketsAndSort();

    final ox = ray.origin.x;
    final oy = ray.origin.y;
    final dx = ray.direction.x;
    final dy = ray.direction.y;

    final double rayMinX;
    final double rayMaxX;
    final double rayMinY;
    final double rayMaxY;

    if (maxDistance.isFinite) {
      final ex = ox + dx * maxDistance;
      final ey = oy + dy * maxDistance;
      rayMinX = math.min(ox, ex);
      rayMaxX = math.max(ox, ex);
      rayMinY = math.min(oy, ey);
      rayMaxY = math.max(oy, ey);
    } else {
      rayMinX = dx < 0 ? -double.infinity : ox;
      rayMaxX = dx > 0 ? double.infinity : ox;
      rayMinY = dy < 0 ? -double.infinity : oy;
      rayMaxY = dy > 0 ? double.infinity : oy;
    }

    _collectBucketRayCandidates(
      _activeItems,
      rayMinX,
      rayMaxX,
      rayMinY,
      rayMaxY,
      out,
    );
    _collectBucketRayCandidates(
      _passiveItems,
      rayMinX,
      rayMaxX,
      rayMinY,
      rayMaxY,
      out,
    );
    _collectBucketRayCandidates(
      _inactiveItems,
      rayMinX,
      rayMaxX,
      rayMinY,
      rayMaxY,
      out,
    );
  }

  static void _collectBucketRayCandidates<H extends Hitbox<H>>(
    List<H> sortedBucket,
    double rayMinX,
    double rayMaxX,
    double rayMinY,
    double rayMaxY,
    List<H> out,
  ) {
    final len = sortedBucket.length;
    for (var i = 0; i < len; i++) {
      final item = sortedBucket[i];
      final box = item.aabb;
      if (box.min.x > rayMaxX) {
        break;
      }
      if (box.max.x < rayMinX || box.max.y < rayMinY || box.min.y > rayMaxY) {
        continue;
      }
      out.add(item);
    }
  }
}
