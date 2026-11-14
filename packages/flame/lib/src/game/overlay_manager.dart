import 'dart:async';
import 'dart:collection';

import 'package:flame/src/game/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Signature for building an overlay widget rendered on top of a [Game].
typedef OverlayBuilderFunction = Widget Function(
  BuildContext context,
  Game game,
);

/// Signature for wrapping an animated overlay [child] with an enter/exit
/// transition driven by [animation].
typedef OverlayTransitionBuilder = Widget Function(
  BuildContext context,
  Animation<double> animation,
  Widget child,
);

/// Controls the registration, ordering, and visibility of Flutter widget
/// overlays displayed above a [Game] without rebuilding the underlying
/// `GameWidget` or detaching its `RenderGameWidget`.
class OverlayManager(final Game _game) {
  final List<_OverlayData> _activeOverlays = [];
  final Map<String, _RegisteredOverlayEntry> _entries = {};
  final ValueNotifier<int> _buildRevision = ValueNotifier<int>(0);

  /// Monotonically increasing revision notified whenever active overlays or
  /// registered overlay builders change.
  ///
  /// Subscribed to by the isolated `OverlayHost` widget so toggling overlays
  /// rebuilds only the overlay layer rather than the entire `GameWidget`.
  ValueListenable<int> get buildRevision => _buildRevision;

  void _notifyOverlayHost() {
    _buildRevision.value++;
  }

  /// The names of all currently active overlays, ordered by ascending
  /// `priority`.
  UnmodifiableListView<String> get activeOverlays {
    return UnmodifiableListView(_activeOverlays.map((overlay) => overlay.name));
  }

  /// The names of all registered overlays.
  UnmodifiableListView<String> get registeredOverlays {
    return UnmodifiableListView(_entries.keys);
  }

  /// Returns whether [overlayName] is currently active.
  bool isActive(String overlayName) =>
      _activeOverlays.any((overlay) => overlay.name == overlayName);

  /// Clears all active overlays.
  void clear() {
    if (_activeOverlays.isNotEmpty) {
      _activeOverlays.clear();
      _notifyOverlayHost();
    }
  }

  /// Marks [overlayName] to be rendered at [priority] (smaller renders first).
  bool add(String overlayName, {int priority = 0}) {
    final setChanged = _addImpl(priority: priority, name: overlayName);
    if (setChanged) {
      _notifyOverlayHost();
    }
    return setChanged;
  }

  /// Marks all [overlayNames] to be rendered.
  void addAll(Iterable<String> overlayNames) {
    final initialCount = _activeOverlays.length;
    overlayNames.forEach((overlayName) => _addImpl(name: overlayName));
    if (initialCount != _activeOverlays.length) {
      _notifyOverlayHost();
    }
  }

  bool _addImpl({required String name, int priority = 0}) {
    assert(
      _entries.containsKey(name),
      'Trying to add an unknown overlay "$name"',
    );
    if (isActive(name)) {
      return false;
    }
    _activeOverlays.add(_OverlayData(priority: priority, name: name));
    _activeOverlays.sort(_compare);
    return true;
  }

  _OverlayData? _getOverlay(String name) {
    return _activeOverlays.where((overlay) => overlay.name == name).firstOrNull;
  }

  /// Registers a named overlay [builder], optionally configured with animated
  /// enter/exit transitions.
  void addEntry(
    String name,
    OverlayBuilderFunction builder, {
    OverlayTransitionBuilder? transitionBuilder,
    Duration transitionDuration = Duration.zero,
    Duration? reverseTransitionDuration,
  }) {
    final existedActive = isActive(name);
    _entries[name] = _RegisteredOverlayEntry(
      builder: builder,
      transitionBuilder: transitionBuilder,
      transitionDuration: transitionDuration,
      reverseTransitionDuration: reverseTransitionDuration,
    );
    if (existedActive) {
      _notifyOverlayHost();
    }
  }

  /// Convenience helper to register an overlay with smooth enter/exit
  /// transitions (defaulting to a 220 ms [FadeTransition] when
  /// [transitionBuilder] is omitted).
  void addAnimatedEntry(
    String name,
    OverlayBuilderFunction builder, {
    Duration duration = const Duration(milliseconds: 220),
    Duration? reverseDuration,
    OverlayTransitionBuilder? transitionBuilder,
  }) {
    addEntry(
      name,
      builder,
      transitionDuration: duration,
      reverseTransitionDuration: reverseDuration,
      transitionBuilder: transitionBuilder,
    );
  }

  /// Hides [overlayName].
  ///
  /// If [overlayName] was registered with an animated transition, its widget
  /// stays mounted solely for the reverse exit animation (with pointer & focus
  /// events disabled) before unmounting automatically.
  bool remove(String overlayName) {
    final overlay = _getOverlay(overlayName);
    final hasRemoved = _activeOverlays.remove(overlay);
    if (hasRemoved) {
      _notifyOverlayHost();
    }
    return hasRemoved;
  }

  /// Hides multiple overlays specified in [overlayNames].
  void removeAll(Iterable<String> overlayNames) {
    final initialCount = _activeOverlays.length;
    _activeOverlays.removeWhere(
      (overlay) => overlayNames.contains(overlay.name),
    );
    if (_activeOverlays.length != initialCount) {
      _notifyOverlayHost();
    }
  }

  /// Toggles whether [overlayName] is active.
  bool toggle(String overlayName, {int priority = 0}) {
    if (isActive(overlayName)) {
      return remove(overlayName);
    } else {
      return add(overlayName, priority: priority);
    }
  }

  /// Sets the active state of [overlayName] to [active].
  bool setActive(String overlayName, {required bool active, int priority = 0}) {
    if (active == isActive(overlayName)) {
      return false;
    }
    if (active) {
      return add(overlayName, priority: priority);
    } else {
      return remove(overlayName);
    }
  }

  @internal
  List<Widget> buildCurrentOverlayWidgets(BuildContext context) {
    final widgets = <Widget>[];
    for (final overlay in _activeOverlays) {
      final entry = _entries[overlay.name]!;
      widgets.add(
        KeyedSubtree(
          key: ValueKey(overlay),
          child: entry.builder(context, _game),
        ),
      );
    }
    return widgets;
  }

  int _compare(_OverlayData a, _OverlayData b) {
    return a.priority - b.priority;
  }
}

@immutable
class const _RegisteredOverlayEntry({
  required final OverlayBuilderFunction builder,
  final OverlayTransitionBuilder? transitionBuilder,
  final Duration transitionDuration = Duration.zero,
  final Duration? reverseTransitionDuration,
}) {
  bool get isAnimated =>
      transitionDuration > Duration.zero ||
      (reverseTransitionDuration != null &&
          reverseTransitionDuration! > Duration.zero) ||
      transitionBuilder != null;
}

@immutable
class const _OverlayData({
  required final int priority,
  required final String name,
}) {
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _OverlayData &&
          runtimeType == other.runtimeType &&
          priority == other.priority &&
          name == other.name;

  @override
  int get hashCode => priority.hashCode ^ name.hashCode;
}

/// Isolated Flutter host widget that subscribes to
/// [OverlayManager.buildRevision] so overlay changes never rebuild
/// `GameWidgetState` or `RenderGameWidget`.
@internal
class const OverlayHost({
  required final Game game,
  super.key,
}) extends StatefulWidget {
  @override
  State<OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState() extends State<OverlayHost> {
  final Map<String, int> _activeAnimatedPriorities = {};
  final Map<String, int> _exitingAnimatedPriorities = {};
  int _buildDepth = 0;
  bool _pendingMicrotaskRebuild = false;

  @override
  void initState() {
    super.initState();
    widget.game.overlays.buildRevision.addListener(_onOverlaysChanged);
  }

  @override
  void didUpdateWidget(OverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game != widget.game) {
      oldWidget.game.overlays.buildRevision.removeListener(_onOverlaysChanged);
      _activeAnimatedPriorities.clear();
      _exitingAnimatedPriorities.clear();
      widget.game.overlays.buildRevision.addListener(_onOverlaysChanged);
    }
  }

  @override
  void dispose() {
    widget.game.overlays.buildRevision.removeListener(_onOverlaysChanged);
    super.dispose();
  }

  void _onOverlaysChanged() {
    if (!mounted) {
      return;
    }
    if (_buildDepth > 0) {
      if (!_pendingMicrotaskRebuild) {
        _pendingMicrotaskRebuild = true;
        Future.microtask(() {
          _pendingMicrotaskRebuild = false;
          if (mounted) {
            setState(() {});
          }
        });
      }
    } else {
      setState(() {});
    }
  }

  void _handleAnimatedExitComplete(String name) {
    if (_exitingAnimatedPriorities.remove(name) != null) {
      _onOverlaysChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildDepth++;
    try {
      final manager = widget.game.overlays;
      final currentActiveNames = <String>{};
      for (final data in manager._activeOverlays) {
        currentActiveNames.add(data.name);
        _exitingAnimatedPriorities.remove(data.name);
        final entry = manager._entries[data.name];
        if (entry != null && entry.isAnimated) {
          _activeAnimatedPriorities[data.name] = data.priority;
        }
      }

      // Transition any previously-active animated overlay that was just removed
      // into the exiting map so its reverse animation can finish cleanly.
      final removedAnimated = <String>[];
      _activeAnimatedPriorities.forEach((name, priority) {
        if (!currentActiveNames.contains(name)) {
          removedAnimated.add(name);
          if (manager._entries.containsKey(name)) {
            _exitingAnimatedPriorities[name] = priority;
          }
        }
      });
      for (final name in removedAnimated) {
        _activeAnimatedPriorities.remove(name);
      }

      if (manager._activeOverlays.isEmpty &&
          _exitingAnimatedPriorities.isEmpty) {
        return const SizedBox.shrink();
      }

      final slots = <({int priority, int order, Widget widget})>[];
      var order = 0;

      for (final overlay in manager._activeOverlays) {
        final entry = manager._entries[overlay.name];
        if (entry == null) {
          continue;
        }
        if (entry.isAnimated) {
          slots.add((
            priority: overlay.priority,
            order: order++,
            widget: Positioned.fill(
              key: ValueKey<String>('flame_animated_overlay_${overlay.name}'),
              child: _AnimatedOverlaySlot(
                name: overlay.name,
                game: widget.game,
                entry: entry,
                isActive: true,
                onExitComplete: _handleAnimatedExitComplete,
              ),
            ),
          ));
        } else {
          slots.add((
            priority: overlay.priority,
            order: order++,
            widget: KeyedSubtree(
              key: ValueKey(overlay),
              child: entry.builder(context, widget.game),
            ),
          ));
        }
      }

      _exitingAnimatedPriorities.forEach((name, priority) {
        final entry = manager._entries[name];
        if (entry == null) {
          return;
        }
        slots.add((
          priority: priority,
          order: order++,
          widget: Positioned.fill(
            key: ValueKey<String>('flame_animated_overlay_$name'),
            child: _AnimatedOverlaySlot(
              name: name,
              game: widget.game,
              entry: entry,
              isActive: false,
              onExitComplete: _handleAnimatedExitComplete,
            ),
          ),
        ));
      });

      if (slots.length > 1) {
        slots.sort((a, b) {
          final cmp = a.priority.compareTo(b.priority);
          return cmp != 0 ? cmp : a.order.compareTo(b.order);
        });
      }

      return Stack(
        children: [
          for (final slot in slots) slot.widget,
        ],
      );
    } finally {
      _buildDepth--;
    }
  }
}

class const _AnimatedOverlaySlot({
  required final String name,
  required final Game game,
  required final _RegisteredOverlayEntry entry,
  required final bool isActive,
  required final ValueChanged<String> onExitComplete,
}) extends StatefulWidget {
  @override
  State<_AnimatedOverlaySlot> createState() => _AnimatedOverlaySlotState();
}

class _AnimatedOverlaySlotState()
    extends State<_AnimatedOverlaySlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.entry.transitionDuration,
      reverseDuration:
          widget.entry.reverseTransitionDuration ??
          widget.entry.transitionDuration,
    )..addStatusListener(_onStatusChanged);

    if (widget.isActive) {
      if (widget.entry.transitionDuration == Duration.zero) {
        _controller.value = 1.0;
      } else {
        _controller.forward();
      }
    } else {
      _controller.value = 1.0;
      _controller.reverse();
    }
  }

  @override
  void didUpdateWidget(_AnimatedOverlaySlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.entry.transitionDuration;
    _controller.reverseDuration =
        widget.entry.reverseTransitionDuration ??
        widget.entry.transitionDuration;
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        if (widget.entry.transitionDuration == Duration.zero) {
          _controller.value = 1.0;
        } else {
          _controller.forward();
        }
      } else {
        final rev =
            widget.entry.reverseTransitionDuration ??
            widget.entry.transitionDuration;
        if (rev == Duration.zero) {
          _controller.value = 0.0;
          widget.onExitComplete(widget.name);
        } else {
          _controller.reverse();
        }
      }
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.isActive) {
      widget.onExitComplete(widget.name);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static Widget _defaultFadeTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    var built = widget.entry.builder(context, widget.game);
    if (built is Positioned || built is PositionedDirectional) {
      built = Stack(children: [built]);
    }
    final transition = widget.entry.transitionBuilder ?? _defaultFadeTransition;
    final animated = transition(context, _controller, built);
    if (!widget.isActive) {
      return IgnorePointer(
        child: ExcludeFocus(
          child: animated,
        ),
      );
    }
    return animated;
  }
}
