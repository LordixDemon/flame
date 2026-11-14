import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/core/component.dart';

/// Lightweight semantic tag mixin for [Component]s queried by [WorldQuery].
mixin HasTags on Component {
  Set<String>? _tags;

  /// Read-only view of semantic tags attached to this component.
  Set<String> get tags =>
      _tags == null ? const <String>{} : Set<String>.unmodifiable(_tags!);

  void _notifyTagMutation() {
    var cursor = parent;
    while (cursor != null) {
      if (cursor is World) {
        cursor.revalidateQueriesFor(this);
        break;
      }
      cursor = cursor.parent;
    }
  }

  /// Attaches [tag] to this component (`true` if newly added).
  bool addTag(String tag) {
    final changed = (_tags ??= <String>{}).add(tag);
    if (changed) {
      _notifyTagMutation();
    }
    return changed;
  }

  /// Attaches all [newTags] to this component.
  void addTags(Iterable<String> newTags) {
    final set = _tags ??= <String>{};
    final before = set.length;
    set.addAll(newTags);
    if (set.length != before) {
      _notifyTagMutation();
    }
  }

  /// Removes [tag] from this component (`true` if present).
  bool removeTag(String tag) {
    final changed = _tags?.remove(tag) ?? false;
    if (changed) {
      _notifyTagMutation();
    }
    return changed;
  }

  /// Removes all semantic tags from this component.
  void clearTags() {
    final set = _tags;
    if (set != null && set.isNotEmpty) {
      set.clear();
      _notifyTagMutation();
    }
  }

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
  this.includeSubtree = true,
  this.onMatched,
  this.onUnmatched,
}) {
  /// Whether nested descendants inside layer/group containers under `World`
  /// are indexed in addition to direct `world.children` (`true` by default).
  final bool includeSubtree;
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

  /// Re-evaluates a single mounted [candidate] in `O(1)` when its tags or
  /// filter-relevant state change in place.
  void revalidate(Component candidate) {
    final nowMatches = candidate.parent != null && matches(candidate);
    if (nowMatches) {
      final typed = candidate as T;
      if (_matchedSet.add(typed)) {
        _matched.add(typed);
        onMatched?.call(typed);
      }
    } else if (candidate is T && _matchedSet.remove(candidate)) {
      _matched.remove(candidate);
      onUnmatched?.call(candidate);
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
