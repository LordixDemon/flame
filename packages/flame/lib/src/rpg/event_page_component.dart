import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/rpg/event_fiber.dart';
import 'package:flame/src/rpg/event_script.dart';
import 'package:flame/src/rpg/world_state_blackboard.dart';

/// Single conditional behavior page (`1..N`) inside an [EventPageComponent].
class EventPage({
  required this.condition,
  required this.trigger,
  required this.script,
  this.graphicId = '',
  this.solid = true,
  this.through = false,
}) {
  final EventPageCondition condition;
  final EventTriggerMode trigger;
  final EventScript script;
  final String graphicId;
  final bool solid;
  final bool through;
}

/// RPG Maker-style world entity component managing ordered [EventPage]s
/// (`Page 0 .. Page N-1`), reactively activating the **highest-index** page
/// whose [EventPageCondition] holds in [blackboard] **without per-frame
/// polling**, and driving `autorun`, `parallel`, and interactive [EventFiber]
/// execution.
class EventPageComponent({
  required this.mapId,
  required this.eventId,
  required this.blackboard,
  required this.pages,
  this.commonEvents = const <String, EventScript>{},
  this.onEmitAction,
  this.onAutorunLockChanged,
  this.onActivePageChanged,
  super.position,
  super.size,
  super.anchor,
  super.priority,
  super.key,
}) extends PositionComponent {
  final String mapId;
  final String eventId;
  final WorldStateBlackboard blackboard;
  final List<EventPage> pages;
  final Map<String, EventScript> commonEvents;
  final void Function(String actionName, Map<String, Object?> params)?
  onEmitAction;

  /// Invoked with `locked: true` when an `autorun` fiber starts locking player
  /// input, and `locked: false` when it finishes or switches away.
  final void Function({required bool locked})? onAutorunLockChanged;

  final void Function(int? pageIndex, EventPage? page)? onActivePageChanged;

  final Set<int> _watchedSwitches = <int>{};
  final Set<int> _watchedVars = <int>{};
  final Set<String> _watchedSelfChannels = <String>{};
  bool _hasCustomPredicates = false;

  int? _activePageIndex;
  EventFiber? _foregroundFiber;
  EventFiber? _parallelFiber;
  bool _autorunHoldingLock = false;
  int _pageEvaluationCount = 0;

  /// Currently active 0-based page index, or `null` if no page matches.
  int? get activePageIndex => _activePageIndex;

  /// Currently active [EventPage], or `null` if no page matches.
  EventPage? get activePage =>
      _activePageIndex == null ? null : pages[_activePageIndex!];

  /// Active foreground (`actionButton` / `playerTouch` / `eventTouch` /
  /// `autorun`) fiber, if running.
  EventFiber? get foregroundFiber => _foregroundFiber;

  /// Active background `parallel` fiber, if running.
  EventFiber? get parallelFiber => _parallelFiber;

  /// Whether an active `autorun` fiber currently holds a cutscene input lock.
  bool get isAutorunLockingInput => _autorunHoldingLock;

  /// Number of times page conditions were evaluated (diagnostic proving `0`
  /// per-frame polling when unrelated blackboard keys mutate).
  int get pageEvaluationCount => _pageEvaluationCount;

  @override
  void onMount() {
    super.onMount();
    _bindDependencies();
    _reevaluatePages();
  }

  @override
  void onRemove() {
    _unbindDependencies();
    _setAutorunLock(locked: false);
    super.onRemove();
  }

  /// Triggers the active page if its mode matches [trigger] (`actionButton`,
  /// `playerTouch`, or `eventTouch`) and no foreground fiber is already busy.
  bool triggerInteraction(EventTriggerMode trigger) {
    final page = activePage;
    if (page == null || _foregroundFiber != null) {
      return false;
    }
    final matches =
        page.trigger == trigger ||
        (page.trigger == EventTriggerMode.eventTouch &&
            trigger == EventTriggerMode.playerTouch);
    if (!matches) {
      return false;
    }
    _foregroundFiber = _spawnFiber(page.script);
    return true;
  }

  @override
  void update(double dt) {
    super.update(dt);
    final page = activePage;

    if (page != null &&
        page.trigger == EventTriggerMode.autorun &&
        _foregroundFiber == null) {
      _foregroundFiber = _spawnFiber(page.script);
      _setAutorunLock(locked: true);
    }

    final fg = _foregroundFiber;
    if (fg != null) {
      fg.tick(dt);
      if (fg.isFinished) {
        _foregroundFiber = null;
        _setAutorunLock(locked: false);
      }
    }

    if (page != null && page.trigger == EventTriggerMode.parallel) {
      _parallelFiber ??= _spawnFiber(page.script);
      _parallelFiber!.tick(dt);
      if (_parallelFiber != null && _parallelFiber!.isFinished) {
        _parallelFiber = null;
      }
    }
  }

  EventFiber _spawnFiber(EventScript script) {
    return EventFiber(
      blackboard: blackboard,
      rootScript: script,
      mapId: mapId,
      eventId: eventId,
      commonEvents: commonEvents,
      onEmitAction: onEmitAction,
    );
  }

  void _setAutorunLock({required bool locked}) {
    if (_autorunHoldingLock != locked) {
      _autorunHoldingLock = locked;
      onAutorunLockChanged?.call(locked: locked);
    }
  }

  void _bindDependencies() {
    for (final p in pages) {
      final c = p.condition;
      _watchedSwitches.addAll(c.requiredSwitches.keys);
      for (final vc in c.variableConditions) {
        _watchedVars.add(vc.variableId);
      }
      _watchedSelfChannels.addAll(c.requiredSelfSwitches.keys);
      if (c.customPredicate != null) {
        _hasCustomPredicates = true;
      }
    }
    for (final sw in _watchedSwitches) {
      blackboard.watchSwitch(sw, _reevaluatePages);
    }
    for (final v in _watchedVars) {
      blackboard.watchVariable(v, _reevaluatePages);
    }
    for (final ch in _watchedSelfChannels) {
      blackboard.watchSelfSwitch(mapId, eventId, ch, _reevaluatePages);
    }
    if (_hasCustomPredicates) {
      blackboard.addGlobalListener(_reevaluatePages);
    }
  }

  void _unbindDependencies() {
    for (final sw in _watchedSwitches) {
      blackboard.unwatchSwitch(sw, _reevaluatePages);
    }
    for (final v in _watchedVars) {
      blackboard.unwatchVariable(v, _reevaluatePages);
    }
    for (final ch in _watchedSelfChannels) {
      blackboard.unwatchSelfSwitch(mapId, eventId, ch, _reevaluatePages);
    }
    if (_hasCustomPredicates) {
      blackboard.removeGlobalListener(_reevaluatePages);
    }
    _watchedSwitches.clear();
    _watchedVars.clear();
    _watchedSelfChannels.clear();
    _hasCustomPredicates = false;
  }

  void _reevaluatePages() {
    _pageEvaluationCount++;
    int? matched;
    for (var i = pages.length - 1; i >= 0; i--) {
      if (pages[i].condition.isSatisfied(
        blackboard,
        mapId: mapId,
        eventId: eventId,
      )) {
        matched = i;
        break;
      }
    }
    if (matched == _activePageIndex) {
      return;
    }
    _activePageIndex = matched;
    _parallelFiber = null;

    if (_autorunHoldingLock &&
        (matched == null ||
            pages[matched].trigger != EventTriggerMode.autorun)) {
      _foregroundFiber = null;
      _setAutorunLock(locked: false);
    }

    onActivePageChanged?.call(matched, activePage);
  }
}
