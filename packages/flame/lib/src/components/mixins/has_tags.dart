import 'package:flame/src/components/core/component.dart';

/// Lightweight semantic tag mixin for [Component]s queried by `WorldQuery`.
mixin HasTags on Component {
  Set<String>? _tags;

  /// Read-only view of semantic tags attached to this component.
  Set<String> get tags =>
      _tags == null ? const <String>{} : Set<String>.unmodifiable(_tags!);

  void _notifyTagMutation() {
    enclosingWorld()?.revalidateQueriesFor(this);
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
