import 'package:flame/src/components/core/component.dart';

/// Scoped modal/cutscene/tutorial input layer inside an [InputContextStack].
class InputContext({
  required this.name,
  this.priority = 0,
  this.blocksLowerContexts = true,
  Iterable<String>? allowedActions,
  Iterable<Component>? allowedTargets,
  var bool enabled = true,
}) {
  /// Unique context identifier (e.g. `'gameplay'`, `'modal_dialog'`,
  /// `'tutorial_step_2'`).
  final String name;

  /// Higher priority contexts are evaluated first.
  final int priority;

  /// When `true`, lower-priority contexts cannot receive actions or pointer
  /// targets rejected by this context.
  final bool blocksLowerContexts;

  /// Whitelist of permitted semantic actions (`null` allows all actions).
  final Set<String>? allowedActions = allowedActions != null
      ? Set<String>.of(allowedActions)
      : null;

  /// Whitelist of permitted interactive [Component] targets (`null` allows all
  /// targets; useful for spotlighting a single tile/button during tutorials!).
  final Set<Component>? allowedTargets = allowedTargets != null
      ? Set<Component>.of(allowedTargets)
      : null;

  /// Whether this context is currently active.
  bool isEnabled = enabled;

  /// Checks whether [action] is permitted by this layer alone.
  bool permitsAction(String action) =>
      allowedActions == null || allowedActions!.contains(action);

  /// Checks whether [target] (or any of its ancestors) is permitted by this
  /// layer alone.
  bool permitsTarget(Component target) {
    final whitelist = allowedTargets;
    if (whitelist == null) {
      return true;
    }
    Component? cursor = target;
    while (cursor != null) {
      if (whitelist.contains(cursor)) {
        return true;
      }
      cursor = cursor.parent;
    }
    return false;
  }
}

/// Priority-ordered modal input stack cleanly gating gameplay, dialogs,
/// cutscenes, and tutorial spotlights without scattering boolean lock flags
/// across components.
class InputContextStack() {
  final List<InputContext> _stack = <InputContext>[];

  /// Read-only view of contexts ordered from highest to lowest priority.
  List<InputContext> get contexts => List<InputContext>.unmodifiable(_stack);

  /// Pushes or replaces a context with the same `name`, maintaining descending
  /// `(priority, insertionOrder)` sort.
  void push(InputContext context) {
    _stack.removeWhere((c) => c.name == context.name);
    var insertAt = _stack.length;
    for (var i = 0; i < _stack.length; i++) {
      // Equal priority puts the newly pushed context ahead of older ones.
      if (context.priority >= _stack[i].priority) {
        insertAt = i;
        break;
      }
    }
    _stack.insert(insertAt, context);
  }

  /// Removes the top-most enabled context, returning it or `null` if empty.
  InputContext? pop() => _stack.isEmpty ? null : _stack.removeAt(0);

  /// Removes the context matching [name], returning `true` if found.
  bool removeByName(String name) {
    final before = _stack.length;
    _stack.removeWhere((c) => c.name == name);
    return _stack.length != before;
  }

  /// Evaluates whether semantic [action] is allowed through the active context
  /// stack.
  bool isActionAllowed(String action) {
    if (_stack.isEmpty) {
      return true;
    }
    for (var i = 0; i < _stack.length; i++) {
      final ctx = _stack[i];
      if (!ctx.isEnabled) {
        continue;
      }
      if (ctx.permitsAction(action)) {
        return true;
      }
      if (ctx.blocksLowerContexts) {
        return false;
      }
    }
    return true;
  }

  /// Evaluates whether pointer/tap interaction with [target] is allowed through
  /// the active context stack.
  bool isTargetAllowed(Component target) {
    if (_stack.isEmpty) {
      return true;
    }
    for (var i = 0; i < _stack.length; i++) {
      final ctx = _stack[i];
      if (!ctx.isEnabled) {
        continue;
      }
      if (ctx.permitsTarget(target)) {
        return true;
      }
      if (ctx.blocksLowerContexts) {
        return false;
      }
    }
    return true;
  }

  /// Clears all registered input contexts.
  void clear() => _stack.clear();
}
