import 'package:flame/src/components/core/component.dart';

/// Lightweight semantic tag mixin for [Component]s queried by [WorldQuery].
mixin HasTags on Component {
  Set<String>? _tags;

  /// Read-only view of semantic tags attached to this component.
  Set<String> get tags =>
      _tags == null ? const <String>{} : Set<String>.unmodifiable(_tags!);

  /// Attaches [tag] to this component (`true` if newly added).
  bool addTag(String tag) => (_tags ??= <String>{}).add(tag);

  /// Attaches all [newTags] to this component.
  void addTags(Iterable<String> newTags) =>
      (_tags ??= <String>{}).addAll(newTags);

  /// Removes [tag] from this component (`true` if present).
  bool removeTag(String tag) => _tags?.remove(tag) ?? false;

  /// Returns `true` when this component carries [tag].
  bool hasTag(String tag) => _tags?.contains(tag) ?? false;
}

/// Cached, multi-constraint reactive entity query (`O(1)` read access,
/// incremental `O(1)` membership maintenance on child add/remove) supporting
/// base type `T`, secondary trait/predicate checks, required [HasTags] tags,
/// and exclusion filters.
class WorldQuery<T extends Component>({
  final bool Function(T component)? filter,
  Iterable<String> withTags = const [],
  Iterable<String> withoutTags = const [],
  this.onMatched,
  this.onUnmatched,
}) {
  final Set<String> _withTags = Set<String>.of(withTags);
  final Set<String> _withoutTags = Set<String>.of(withoutTags);

  final List<T> _matched = <T>[];
  final Set<T> _matchedSet = <T>{};
  late final List<T> _unmodifiableView = List<T>.unmodifiable(_matched);

  /// Optional callback fired when a component enters this query's result set.
  final void Function(T component)? onMatched;

  /// Optional callback fired when a component leaves this query's result set.
  final void Function(T component)? onUnmatched;

  /// Zero-allocation read-only view of currently matched components.
  List<T> get items => _unmodifiableView;

  /// Number of matched components.
  int get length => _matched.length;

  /// Whether zero components currently match.
  bool get isEmpty => _matched.isEmpty;

  /// Whether at least one component currently matches.
  bool get isNotEmpty => _matched.isNotEmpty;

  /// Evaluates whether [candidate] satisfies all type, tag, and predicate
  /// constraints of this query.
  bool matches(Component candidate) {
    if (candidate is! T) {
      return false;
    }
    if (_withTags.isNotEmpty) {
      if (candidate is! HasTags) {
        return false;
      }
      for (final tag in _withTags) {
        if (!candidate.hasTag(tag)) {
          return false;
        }
      }
    }
    if (_withoutTags.isNotEmpty && candidate is HasTags) {
      for (final tag in _withoutTags) {
        if (candidate.hasTag(tag)) {
          return false;
        }
      }
    }
    final predicate = filter;
    if (predicate != null && !predicate(candidate)) {
      return false;
    }
    return true;
  }

  /// Re-evaluates all [candidates] from scratch (used on initial registration
  /// or tag mutation).
  void rebuild(Iterable<Component> candidates) {
    for (var i = _matched.length - 1; i >= 0; i--) {
      final existing = _matched[i];
      if (!candidates.contains(existing) || !matches(existing)) {
        _matchedSet.remove(existing);
        _matched.removeAt(i);
        onUnmatched?.call(existing);
      }
    }
    for (final c in candidates) {
      if (matches(c)) {
        final typed = c as T;
        if (_matchedSet.add(typed)) {
          _matched.add(typed);
          onMatched?.call(typed);
        }
      }
    }
  }

  /// Incrementally updates membership for a single [child] change.
  void handleChildChanged(Component child, ChildrenChangeType type) {
    if (type == ChildrenChangeType.added) {
      if (matches(child)) {
        final typed = child as T;
        if (_matchedSet.add(typed)) {
          _matched.add(typed);
          onMatched?.call(typed);
        }
      }
    } else if (child is T && _matchedSet.remove(child)) {
      _matched.remove(child);
      onUnmatched?.call(child);
    }
  }

  /// Clears cached results without firing callbacks.
  void clear() {
    _matched.clear();
    _matchedSet.clear();
  }
}
