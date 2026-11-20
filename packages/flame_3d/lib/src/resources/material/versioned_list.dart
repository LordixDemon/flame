import 'dart:collection';

import 'package:meta/meta.dart';

/// A list whose writes are reported to its owner ([onChanged]), for the
/// lists a material reads (its palettes): every write that changes an
/// element or the length calls it, and writing the element already held
/// does not.
@internal
class VersionedList<E>(Iterable<E> elements) extends ListBase<E> {
  final List<E> _elements = List.of(elements);

  /// Called on every change, set by the owner.
  void Function()? onChanged;

  void _changed() => onChanged?.call();

  @override
  int get length => _elements.length;

  @override
  set length(int value) {
    if (value == _elements.length) {
      return;
    }
    _elements.length = value;
    _changed();
  }

  @override
  E operator [](int index) => _elements[index];

  @override
  void operator []=(int index, E value) {
    if (_elements[index] == value) {
      return;
    }
    _elements[index] = value;
    _changed();
  }

  @override
  void add(E element) {
    _elements.add(element);
    _changed();
  }

  @override
  void addAll(Iterable<E> iterable) {
    final before = _elements.length;
    _elements.addAll(iterable);
    if (_elements.length != before) {
      _changed();
    }
  }

  @override
  void insert(int index, E element) {
    _elements.insert(index, element);
    _changed();
  }

  @override
  void insertAll(int index, Iterable<E> iterable) {
    final before = _elements.length;
    _elements.insertAll(index, iterable);
    if (_elements.length != before) {
      _changed();
    }
  }
}
