import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui';

import 'package:meta/meta.dart';

/// Zero-query-allocation uniform 2D spatial hash grid supporting points and
/// axis-aligned bounding rectangles across arbitrary negative/positive world
/// coordinates.
///
/// Multi-cell entries registered via [upsertRect] are deduplicated in `O(1)`
/// using an internal integer stamp array (`_visitStamp`), avoiding `Set<T>`
/// allocations during [queryPoint], [queryRect], and [queryRadius].
class SpatialGrid2D<T>({
  final double cellSize = 128.0,
  int initialCapacity = 64,
}) {
  this : assert(cellSize > 0, 'cellSize must be positive: $cellSize');

  final double _invCellSize = 1.0 / cellSize;

  final Map<T, int> _slotOfItem = HashMap<T, int>();
  final List<T?> _items = <T?>[];
  final List<int> _freeSlots = <int>[];

  Float64List _minX = Float64List(initialCapacity < 16 ? 16 : initialCapacity);
  Float64List _minY = Float64List(initialCapacity < 16 ? 16 : initialCapacity);
  Float64List _maxX = Float64List(initialCapacity < 16 ? 16 : initialCapacity);
  Float64List _maxY = Float64List(initialCapacity < 16 ? 16 : initialCapacity);
  Int32List _minCx = Int32List(initialCapacity < 16 ? 16 : initialCapacity);
  Int32List _minCy = Int32List(initialCapacity < 16 ? 16 : initialCapacity);
  Int32List _maxCx = Int32List(initialCapacity < 16 ? 16 : initialCapacity);
  Int32List _maxCy = Int32List(initialCapacity < 16 ? 16 : initialCapacity);
  Int32List _visitStamp = Int32List(
    initialCapacity < 16 ? 16 : initialCapacity,
  );
  int _stampCounter = 1;

  final Map<int, List<int>> _cells = HashMap<int, List<int>>();

  /// Number of live items currently stored in this grid.
  int get itemCount => _slotOfItem.length;

  /// Number of occupied spatial cells currently maintained.
  int get nonEmptyCellCount => _cells.length;

  int _cellCoord(double v) => (v * _invCellSize).floor();

  static int _packCell(int cx, int cy) =>
      ((cx & 0xFFFFFFFF) << 32) | (cy & 0xFFFFFFFF);

  void _ensureSlotCapacity(int neededSlot) {
    if (neededSlot < _minX.length) {
      return;
    }
    var cap = _minX.length * 2;
    while (cap <= neededSlot) {
      cap *= 2;
    }
    _minX = Float64List(cap)..setRange(0, _minX.length, _minX);
    _minY = Float64List(cap)..setRange(0, _minY.length, _minY);
    _maxX = Float64List(cap)..setRange(0, _maxX.length, _maxX);
    _maxY = Float64List(cap)..setRange(0, _maxY.length, _maxY);
    _minCx = Int32List(cap)..setRange(0, _minCx.length, _minCx);
    _minCy = Int32List(cap)..setRange(0, _minCy.length, _minCy);
    _maxCx = Int32List(cap)..setRange(0, _maxCx.length, _maxCx);
    _maxCy = Int32List(cap)..setRange(0, _maxCy.length, _maxCy);
    _visitStamp = Int32List(cap)..setRange(0, _visitStamp.length, _visitStamp);
  }

  void _unlinkSlotFromCells(int slot) {
    final x0 = _minCx[slot];
    final y0 = _minCy[slot];
    final x1 = _maxCx[slot];
    final y1 = _maxCy[slot];
    for (var cy = y0; cy <= y1; cy++) {
      for (var cx = x0; cx <= x1; cx++) {
        final key = _packCell(cx, cy);
        final bucket = _cells[key];
        if (bucket != null) {
          bucket.remove(slot);
          if (bucket.isEmpty) {
            _cells.remove(key);
          }
        }
      }
    }
  }

  void _linkSlotIntoCells(int slot, int x0, int y0, int x1, int y1) {
    _minCx[slot] = x0;
    _minCy[slot] = y0;
    _maxCx[slot] = x1;
    _maxCy[slot] = y1;
    for (var cy = y0; cy <= y1; cy++) {
      for (var cx = x0; cx <= x1; cx++) {
        final key = _packCell(cx, cy);
        (_cells[key] ??= <int>[]).add(slot);
      }
    }
  }

  /// Inserts or updates [item] as a zero-area point at `(x, y)`.
  void upsertPoint(T item, double x, double y) {
    upsertBox(item, x, y, x, y);
  }

  /// Inserts or updates [item] occupying axis-aligned [bounds].
  void upsertRect(T item, Rect bounds) {
    upsertBox(item, bounds.left, bounds.top, bounds.right, bounds.bottom);
  }

  /// Inserts or updates [item] occupying `[left, top, right, bottom]`.
  void upsertBox(T item, double left, double top, double right, double bottom) {
    final l = left <= right ? left : right;
    final r = left <= right ? right : left;
    final t = top <= bottom ? top : bottom;
    final b = top <= bottom ? bottom : top;

    final cx0 = _cellCoord(l);
    final cy0 = _cellCoord(t);
    final cx1 = _cellCoord(r);
    final cy1 = _cellCoord(b);

    final existingSlot = _slotOfItem[item];
    if (existingSlot != null) {
      _minX[existingSlot] = l;
      _minY[existingSlot] = t;
      _maxX[existingSlot] = r;
      _maxY[existingSlot] = b;
      if (_minCx[existingSlot] == cx0 &&
          _minCy[existingSlot] == cy0 &&
          _maxCx[existingSlot] == cx1 &&
          _maxCy[existingSlot] == cy1) {
        return;
      }
      _unlinkSlotFromCells(existingSlot);
      _linkSlotIntoCells(existingSlot, cx0, cy0, cx1, cy1);
      return;
    }

    int slot;
    if (_freeSlots.isNotEmpty) {
      slot = _freeSlots.removeLast();
      _items[slot] = item;
    } else {
      slot = _items.length;
      _items.add(item);
    }
    _ensureSlotCapacity(slot);
    _slotOfItem[item] = slot;
    _minX[slot] = l;
    _minY[slot] = t;
    _maxX[slot] = r;
    _maxY[slot] = b;
    _linkSlotIntoCells(slot, cx0, cy0, cx1, cy1);
  }

  /// Removes [item] from the spatial grid, returning `true` if it was present.
  bool remove(T item) {
    final slot = _slotOfItem.remove(item);
    if (slot == null) {
      return false;
    }
    _unlinkSlotFromCells(slot);
    _items[slot] = null;
    _freeSlots.add(slot);
    return true;
  }

  /// Clears all items and cell buckets from the grid.
  void clear() {
    _slotOfItem.clear();
    _items.clear();
    _freeSlots.clear();
    _cells.clear();
  }

  int _nextQueryStamp() {
    var s = ++_stampCounter;
    if (s >= 0x7fffffff) {
      _visitStamp.fillRange(0, _visitStamp.length, 0);
      _stampCounter = 1;
      s = 1;
    }
    return s;
  }

  /// Appends all items whose registered point or rectangle contains `(x, y)`
  /// into [out] (without clearing [out] first), returning the number of items
  /// appended. Performs zero heap allocations.
  int queryPoint(double x, double y, List<T> out) {
    final bucket = _cells[_packCell(_cellCoord(x), _cellCoord(y))];
    if (bucket == null || bucket.isEmpty) {
      return 0;
    }
    var added = 0;
    for (var i = 0; i < bucket.length; i++) {
      final slot = bucket[i];
      if (x >= _minX[slot] &&
          x <= _maxX[slot] &&
          y >= _minY[slot] &&
          y <= _maxY[slot]) {
        out.add(_items[slot] as T);
        added++;
      }
    }
    return added;
  }

  /// Appends all unique items overlapping [bounds] into [out] (without clearing
  /// [out] first), returning the number of items appended. Performs zero heap
  /// allocations.
  int queryRect(Rect bounds, List<T> out) {
    final l = bounds.left;
    final t = bounds.top;
    final r = bounds.right;
    final b = bounds.bottom;
    final cx0 = _cellCoord(l);
    final cy0 = _cellCoord(t);
    final cx1 = _cellCoord(r);
    final cy1 = _cellCoord(b);
    final stamp = _nextQueryStamp();
    var added = 0;

    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        final bucket = _cells[_packCell(cx, cy)];
        if (bucket == null) {
          continue;
        }
        for (var i = 0; i < bucket.length; i++) {
          final slot = bucket[i];
          if (_visitStamp[slot] == stamp) {
            continue;
          }
          _visitStamp[slot] = stamp;
          if (_maxX[slot] >= l &&
              _minX[slot] <= r &&
              _maxY[slot] >= t &&
              _minY[slot] <= b) {
            out.add(_items[slot] as T);
            added++;
          }
        }
      }
    }
    return added;
  }

  /// Like [queryRect], but replaces the contents of [out] instead of adding
  /// to them, without giving up its storage as clearing it first would: a
  /// list that is queried into every frame then allocates nothing.
  ///
  /// Returns the number of items found, which is the new length of [out].
  @internal
  int queryRectInto(Rect bounds, List<T> out) {
    final l = bounds.left;
    final t = bounds.top;
    final r = bounds.right;
    final b = bounds.bottom;
    final cx0 = _cellCoord(l);
    final cy0 = _cellCoord(t);
    final cx1 = _cellCoord(r);
    final cy1 = _cellCoord(b);
    final stamp = _nextQueryStamp();
    var added = 0;

    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        final bucket = _cells[_packCell(cx, cy)];
        if (bucket == null) {
          continue;
        }
        for (var i = 0; i < bucket.length; i++) {
          final slot = bucket[i];
          if (_visitStamp[slot] == stamp) {
            continue;
          }
          _visitStamp[slot] = stamp;
          if (_maxX[slot] >= l &&
              _minX[slot] <= r &&
              _maxY[slot] >= t &&
              _minY[slot] <= b) {
            final item = _items[slot] as T;
            if (added < out.length) {
              out[added] = item;
            } else {
              out.add(item);
            }
            added++;
          }
        }
      }
    }
    out.length = added;
    return added;
  }

  /// Appends all unique items whose registered point or AABB intersects the
  /// circle centered at `(cx, cy)` with [radius] (`>= 0`) into [out], returning
  /// the number of items appended. Performs zero heap allocations.
  int queryRadius(double cx, double cy, double radius, List<T> out) {
    if (radius < 0) {
      return 0;
    }
    final rSq = radius * radius;
    final cellX0 = _cellCoord(cx - radius);
    final cellY0 = _cellCoord(cy - radius);
    final cellX1 = _cellCoord(cx + radius);
    final cellY1 = _cellCoord(cy + radius);
    final stamp = _nextQueryStamp();
    var added = 0;

    for (var gy = cellY0; gy <= cellY1; gy++) {
      for (var gx = cellX0; gx <= cellX1; gx++) {
        final bucket = _cells[_packCell(gx, gy)];
        if (bucket == null) {
          continue;
        }
        for (var i = 0; i < bucket.length; i++) {
          final slot = bucket[i];
          if (_visitStamp[slot] == stamp) {
            continue;
          }
          _visitStamp[slot] = stamp;
          // Closest point on [minX..maxX, minY..maxY] to circle center (cx, cy)
          final nearX = cx < _minX[slot]
              ? _minX[slot]
              : (cx > _maxX[slot] ? _maxX[slot] : cx);
          final nearY = cy < _minY[slot]
              ? _minY[slot]
              : (cy > _maxY[slot] ? _maxY[slot] : cy);
          final dx = cx - nearX;
          final dy = cy - nearY;
          if (dx * dx + dy * dy <= rSq) {
            out.add(_items[slot] as T);
            added++;
          }
        }
      }
    }
    return added;
  }
}
