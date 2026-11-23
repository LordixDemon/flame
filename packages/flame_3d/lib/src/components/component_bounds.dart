part of 'component_3d.dart';

/// {@template component_bounds}
/// The union of the world-space bounds ([Component3D.aabb]) of a set of
/// components that have no [Component3D] parent, such as the components of a
/// [World3D] (see [World3D.sceneBounds]), kept up to date incrementally.
///
/// Components tell their set when their bounds change: when they or one of
/// their descendants move, or when a descendant is added or removed. The set
/// keeps the bounds of its components in a binary tree whose nodes hold the
/// union of their children, so that reading [value] after `k` of `n`
/// components changed costs at most `k * log2(n)` unions (and nothing when
/// none did), instead of `n`. The union is always exactly that of the
/// current bounds of the components.
/// {@endtemplate}
@internal
class ComponentBounds() {
  // The components, by slot.
  final List<Component3D> _components = [];
  final List<Component3D> _changedComponents = [];

  // A complete binary tree of boxes in an array: node `i` has the children
  // `2i` and `2i + 1`, node 1 is the root and the leaves start at
  // `_capacity`, the leaf of slot `s` being node `_capacity + s`. Each node
  // holds six values, its min and max; empty leaves hold an inverted box.
  Float64List _nodes = Float64List(0);
  int _capacity = 0;
  // Whether the inner nodes are out of date: they are recomputed together
  // once few components change again.
  bool _treeStale = false;

  final Aabb3 _union = Aabb3();
  // Whether [_union] is the union of the leaves.
  bool _unionCurrent = false;

  /// The number of components in the set.
  int get length => _components.length;

  /// Whether [component] is in the set.
  bool contains(Component3D component) =>
      identical(component._boundsOwner, this);

  /// Adds [component] to the set.
  void add(Component3D component) {
    assert(component._boundsOwner == null, 'Already in a set of bounds');
    final slot = _components.length;
    if (slot == _capacity) {
      _grow();
    }
    _components.add(component);
    component
      .._boundsOwner = this
      .._boundsSlot = slot;
    _changed(component);
  }

  /// Removes [component] from the set.
  void remove(Component3D component) {
    if (!identical(component._boundsOwner, this)) {
      return;
    }
    if (component._boundsQueued) {
      component._boundsQueued = false;
      _changedComponents.remove(component);
    }
    // The last component takes the slot of the removed one.
    final slot = component._boundsSlot;
    final last = _components.removeLast();
    final lastSlot = _components.length;
    if (!identical(last, component)) {
      _components[slot] = last;
      last._boundsSlot = slot;
      _copyNode(_capacity + lastSlot, _capacity + slot);
      _updatePath(slot);
    }
    _setEmpty(_capacity + lastSlot);
    _updatePath(lastSlot);
    component._boundsOwner = null;
    _unionCurrent = false;
  }

  void _changed(Component3D component) {
    if (!component._boundsQueued) {
      component._boundsQueued = true;
      _changedComponents.add(component);
    }
  }

  /// The union of the bounds of the components, or `null` when there are
  /// none.
  ///
  /// The box is owned by this set and changes when it is read again; copy it
  /// to keep it.
  Aabb3? get value {
    final changed = _changedComponents;
    if (changed.isNotEmpty) {
      for (final component in changed) {
        component._boundsQueued = false;
        _writeLeaf(_capacity + component._boundsSlot, component.aabb);
      }
      if (changed.length * _capacity.bitLength > _capacity) {
        // So many changed that updating their paths would cost more than
        // uniting the leaves: the inner nodes wait for calmer times.
        _treeStale = true;
      } else if (_treeStale) {
        _uniteAll();
        _treeStale = false;
      } else {
        for (final component in changed) {
          _updatePath(component._boundsSlot);
        }
      }
      changed.clear();
      _unionCurrent = false;
    }
    if (_components.isEmpty) {
      return null;
    }
    if (!_unionCurrent) {
      _unionCurrent = true;
      if (_treeStale) {
        _uniteLeaves();
      } else {
        final nodes = _nodes;
        _union.min.setValues(nodes[6], nodes[7], nodes[8]);
        _union.max.setValues(nodes[9], nodes[10], nodes[11]);
      }
    }
    return _union;
  }

  /// Sets [_union] to the union of the leaves that hold a component.
  void _uniteLeaves() {
    final nodes = _nodes;
    var o = _capacity * 6;
    var minX = nodes[o];
    var minY = nodes[o + 1];
    var minZ = nodes[o + 2];
    var maxX = nodes[o + 3];
    var maxY = nodes[o + 4];
    var maxZ = nodes[o + 5];
    for (var slot = 1; slot < _components.length; slot++) {
      o += 6;
      minX = math.min(minX, nodes[o]);
      minY = math.min(minY, nodes[o + 1]);
      minZ = math.min(minZ, nodes[o + 2]);
      maxX = math.max(maxX, nodes[o + 3]);
      maxY = math.max(maxY, nodes[o + 4]);
      maxZ = math.max(maxZ, nodes[o + 5]);
    }
    _union.min.setValues(minX, minY, minZ);
    _union.max.setValues(maxX, maxY, maxZ);
  }

  void _grow() {
    final capacity = _capacity == 0 ? 8 : _capacity * 2;
    final previous = _nodes;
    _nodes = Float64List(capacity * 2 * 6);
    // Every node starts empty: those above empty leaves stay so.
    for (var node = 1; node < capacity * 2; node++) {
      _setEmpty(node);
    }
    for (var slot = 0; slot < _capacity; slot++) {
      _nodes.setRange(
        (capacity + slot) * 6,
        (capacity + slot) * 6 + 6,
        previous,
        (_capacity + slot) * 6,
      );
    }
    _capacity = capacity;
    _treeStale = true;
    _unionCurrent = false;
  }

  /// Recomputes every inner node above a leaf that holds a component.
  void _uniteAll() {
    final nodes = _nodes;
    final count = _components.length;
    if (count == 0) {
      return;
    }
    var level = 1;
    for (var first = _capacity >> 1; first >= 1; first >>= 1) {
      final last = first + ((count - 1) >> level);
      for (var node = first; node <= last; node++) {
        final o = node * 6;
        final a = node * 12;
        final b = a + 6;
        nodes
          ..[o] = math.min(nodes[a], nodes[b])
          ..[o + 1] = math.min(nodes[a + 1], nodes[b + 1])
          ..[o + 2] = math.min(nodes[a + 2], nodes[b + 2])
          ..[o + 3] = math.max(nodes[a + 3], nodes[b + 3])
          ..[o + 4] = math.max(nodes[a + 4], nodes[b + 4])
          ..[o + 5] = math.max(nodes[a + 5], nodes[b + 5]);
      }
      level++;
    }
  }

  void _writeLeaf(int node, Aabb3 box) {
    final o = node * 6;
    final min = box.min;
    final max = box.max;
    _nodes
      ..[o] = min.x
      ..[o + 1] = min.y
      ..[o + 2] = min.z
      ..[o + 3] = max.x
      ..[o + 4] = max.y
      ..[o + 5] = max.z;
  }

  void _setEmpty(int node) {
    final o = node * 6;
    _nodes
      ..[o] = double.infinity
      ..[o + 1] = double.infinity
      ..[o + 2] = double.infinity
      ..[o + 3] = double.negativeInfinity
      ..[o + 4] = double.negativeInfinity
      ..[o + 5] = double.negativeInfinity;
  }

  void _copyNode(int from, int to) {
    _nodes.setRange(to * 6, to * 6 + 6, _nodes, from * 6);
  }

  /// Recomputes the ancestors of the leaf of [slot], up to the first one
  /// that does not change.
  void _updatePath(int slot) {
    if (_treeStale) {
      return;
    }
    for (var node = (_capacity + slot) >> 1; node >= 1; node >>= 1) {
      if (!_unite(node)) {
        return;
      }
    }
  }

  /// Sets [node] to the union of its children; returns whether it changed.
  bool _unite(int node) {
    final nodes = _nodes;
    final o = node * 6;
    final a = node * 12;
    final b = a + 6;
    final minX = math.min(nodes[a], nodes[b]);
    final minY = math.min(nodes[a + 1], nodes[b + 1]);
    final minZ = math.min(nodes[a + 2], nodes[b + 2]);
    final maxX = math.max(nodes[a + 3], nodes[b + 3]);
    final maxY = math.max(nodes[a + 4], nodes[b + 4]);
    final maxZ = math.max(nodes[a + 5], nodes[b + 5]);
    if (nodes[o] == minX &&
        nodes[o + 1] == minY &&
        nodes[o + 2] == minZ &&
        nodes[o + 3] == maxX &&
        nodes[o + 4] == maxY &&
        nodes[o + 5] == maxZ) {
      return false;
    }
    nodes
      ..[o] = minX
      ..[o + 1] = minY
      ..[o + 2] = minZ
      ..[o + 3] = maxX
      ..[o + 4] = maxY
      ..[o + 5] = maxZ;
    return true;
  }
}
