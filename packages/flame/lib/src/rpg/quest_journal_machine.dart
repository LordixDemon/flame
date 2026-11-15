import 'dart:math' as math;

import 'package:flame/src/components/core/signal.dart';
import 'package:flame/src/components/core/world_event_bus.dart';

/// High-level lifecycle status of a quest in [QuestJournalMachine].
enum QuestState() {
  /// Not yet discovered or started.
  locked,

  /// Currently tracked with an active stage.
  active,

  /// Successfully completed.
  completed,

  /// Permanently failed.
  failed,
}

/// Completion rule for objectives within a single [QuestStageDef].
enum ObjectiveGroupMode() {
  /// Every objective in the stage must reach its `targetCount`.
  allOf,

  /// Completing ANY single objective advances the stage (branching choice!).
  anyOf,

  /// Only the first incomplete objective accepts progress at a time.
  sequential,
}

/// Single counter objective inside a [QuestStageDef].
class const QuestObjectiveDef({
  required this.id,
  required this.progressTag,
  this.targetCount = 1,
  this.nextStageOverride,
}) {
  this : assert(targetCount >= 1, 'targetCount must be >= 1.');

  /// Objective identifier within the stage.
  final String id;

  /// Gameplay event tag advancing this objective (e.g. `'slay:slime'`).
  final String progressTag;

  /// Required count (`>= 1`).
  final int targetCount;

  /// Optional stage ID branched to when this specific objective wins an
  /// [ObjectiveGroupMode.anyOf] race.
  final String? nextStageOverride;
}

/// Directed-acyclic-graph (DAG) stage inside a [QuestDef].
class const QuestStageDef({
  required this.id,
  required this.objectives,
  this.mode = ObjectiveGroupMode.allOf,
  this.nextStageId,
  this.failOnEventTag,
  this.failBranchStageId,
}) {
  /// Unique stage ID within the quest.
  final String id;

  /// Objectives active during this stage.
  final List<QuestObjectiveDef> objectives;

  /// Whether all, any, or sequential objectives are required.
  final ObjectiveGroupMode mode;

  /// Next stage ID entered upon completion (`null` marks the quest
  /// [QuestState.completed]!).
  final String? nextStageId;

  /// Optional event tag (e.g. `'npc_died:escort_merchant'`) that triggers stage
  /// failure.
  final String? failOnEventTag;

  /// Optional recovery/alternate stage entered on [failOnEventTag]; when
  /// `null`, [failOnEventTag] marks the entire quest [QuestState.failed].
  final String? failBranchStageId;
}

/// Multi-stage branching quest definition registered in [QuestJournalMachine].
class QuestDef({
  required this.id,
  required this.title,
  required this.initialStageId,
  required List<QuestStageDef> stages,
}) {
  /// Unique quest ID.
  final String id;

  /// Display title.
  final String title;

  /// Entry stage ID activated by [QuestJournalMachine.startQuest].
  final String initialStageId;

  final Map<String, QuestStageDef> _stagesById = <String, QuestStageDef>{
    for (final s in stages) s.id: s,
  };

  /// Looks up a stage by [stageId].
  QuestStageDef? stageById(String stageId) => _stagesById[stageId];
}

/// Event payload dispatched over [WorldEventBus] to drive
/// [QuestJournalMachine].
class const QuestProgressEvent(this.tag, {this.amount = 1}) {
  /// Gameplay event tag (e.g. `'collect:moon_herb'` or `'boss_escaped'`).
  final String tag;

  /// Progress increment (`>= 1`).
  final int amount;
}

class _QuestRuntimeState(
  this.questId,
  this.state,
  this.currentStageId,
) {
  final String questId;
  QuestState state;
  String? currentStageId;
  final Map<String, int> objectiveCounts = <String, int>{};
}

/// Event-driven DAG Quest Journal supporting `allOf`, `anyOf` branching,
/// `sequential` step gates, failure branches, [WorldEventBus] binding, and
/// JSON save/load serialization.
class QuestJournalMachine() {
  final Map<String, QuestDef> _defs = <String, QuestDef>{};
  final Map<String, _QuestRuntimeState> _runtime =
      <String, _QuestRuntimeState>{};

  /// Fired whenever a quest changes state or stage.
  final Signal<({String questId, QuestState state, String? stageId})>
  onQuestUpdated =
      Signal<({String questId, QuestState state, String? stageId})>();

  /// Registers [quest] in the journal catalog.
  void registerQuest(QuestDef quest) {
    _defs[quest.id] = quest;
  }

  /// Queries the current [QuestState] of [questId].
  QuestState stateOf(String questId) =>
      _runtime[questId]?.state ?? QuestState.locked;

  /// Queries the active stage ID of [questId], or `null` if not active.
  String? currentStageOf(String questId) => _runtime[questId]?.currentStageId;

  /// Queries progress `(current, target)` of [objectiveId] in active [questId].
  int objectiveProgress(String questId, String objectiveId) =>
      _runtime[questId]?.objectiveCounts[objectiveId] ?? 0;

  /// Starts [questId] at its `initialStageId` if currently `locked`.
  bool startQuest(String questId) {
    final def = _defs[questId];
    if (def == null) {
      return false;
    }
    final existing = _runtime[questId];
    if (existing != null && existing.state != QuestState.locked) {
      return false;
    }
    if (def.stageById(def.initialStageId) == null) {
      return false;
    }
    final rt = _QuestRuntimeState(
      questId,
      QuestState.active,
      def.initialStageId,
    );
    _runtime[questId] = rt;
    onQuestUpdated.emit((
      questId: questId,
      state: rt.state,
      stageId: rt.currentStageId,
    ));
    return true;
  }

  /// Subscribes this journal directly to [QuestProgressEvent]s on [bus].
  SignalSubscription attachToEventBus(WorldEventBus bus) =>
      bus.on<QuestProgressEvent>(
        (e) => recordEvent(e.tag, amount: e.amount),
      );

  /// Processes a gameplay [eventTag] across all currently [QuestState.active]
  /// quests.
  void recordEvent(String eventTag, {int amount = 1}) {
    if (amount <= 0) {
      return;
    }
    // Snapshot active entries so `onQuestUpdated` listeners can safely call
    // `startQuest` without throwing `ConcurrentModificationError`!
    final snapshot = List<_QuestRuntimeState>.of(_runtime.values);
    for (var idx = 0; idx < snapshot.length; idx++) {
      final rt = snapshot[idx];
      if (rt.state != QuestState.active || rt.currentStageId == null) {
        continue;
      }
      final def = _defs[rt.questId];
      final stage = def?.stageById(rt.currentStageId!);
      if (def == null || stage == null) {
        continue;
      }

      if (stage.failOnEventTag != null && stage.failOnEventTag == eventTag) {
        final recovery = stage.failBranchStageId;
        if (recovery != null && def.stageById(recovery) != null) {
          rt
            ..currentStageId = recovery
            ..objectiveCounts.clear();
        } else {
          rt
            ..state = QuestState.failed
            ..currentStageId = null;
        }
        onQuestUpdated.emit((
          questId: rt.questId,
          state: rt.state,
          stageId: rt.currentStageId,
        ));
        continue;
      }

      var changed = false;
      String? winningOverrideNextStage;

      for (var i = 0; i < stage.objectives.length; i++) {
        final obj = stage.objectives[i];
        final cur = rt.objectiveCounts[obj.id] ?? 0;
        final isDone = cur >= obj.targetCount;

        if (stage.mode == ObjectiveGroupMode.sequential && !isDone) {
          if (obj.progressTag == eventTag) {
            rt.objectiveCounts[obj.id] = math.min(
              obj.targetCount,
              cur + amount,
            );
            changed = true;
          }
          break;
        }

        if (!isDone && obj.progressTag == eventTag) {
          final nextVal = math.min(obj.targetCount, cur + amount);
          rt.objectiveCounts[obj.id] = nextVal;
          changed = true;
          if (stage.mode == ObjectiveGroupMode.anyOf &&
              nextVal >= obj.targetCount) {
            winningOverrideNextStage = obj.nextStageOverride;
            break;
          }
        }
      }

      if (!changed) {
        continue;
      }

      final stageCompleted = switch (stage.mode) {
        ObjectiveGroupMode.allOf ||
        ObjectiveGroupMode.sequential => stage.objectives.every(
          (o) => (rt.objectiveCounts[o.id] ?? 0) >= o.targetCount,
        ),
        ObjectiveGroupMode.anyOf => stage.objectives.any(
          (o) => (rt.objectiveCounts[o.id] ?? 0) >= o.targetCount,
        ),
      };

      if (stageCompleted) {
        final nextStageId = winningOverrideNextStage ?? stage.nextStageId;
        if (nextStageId != null && def.stageById(nextStageId) != null) {
          rt
            ..currentStageId = nextStageId
            ..objectiveCounts.clear();
        } else {
          rt
            ..state = QuestState.completed
            ..currentStageId = null;
        }
      }

      onQuestUpdated.emit((
        questId: rt.questId,
        state: rt.state,
        stageId: rt.currentStageId,
      ));
    }
  }

  /// Serializes active/completed/failed quest states to JSON-compatible map.
  Map<String, Object?> toJson() => <String, Object?>{
    'quests': <String, Object?>{
      for (final e in _runtime.entries)
        e.key: <String, Object?>{
          'state': e.value.state.name,
          'stage': e.value.currentStageId,
          'counts': Map<String, int>.of(e.value.objectiveCounts),
        },
    },
  };

  /// Restores runtime quest progress from a [toJson] snapshot.
  void restoreFromJson(Map<String, Object?> json) {
    _runtime.clear();
    final questsRaw = json['quests'];
    if (questsRaw is! Map<Object?, Object?>) {
      return;
    }
    for (final entry in questsRaw.entries) {
      final qId = entry.key;
      final qVal = entry.value;
      if (qId is! String || qVal is! Map<Object?, Object?>) {
        continue;
      }
      final stateStr = qVal['state'];
      final parsedState = QuestState.values.firstWhere(
        (s) => s.name == stateStr,
        orElse: () => QuestState.locked,
      );
      final stageRaw = qVal['stage'];
      final rt = _QuestRuntimeState(
        qId,
        parsedState,
        stageRaw is String ? stageRaw : null,
      );
      final countsRaw = qVal['counts'];
      if (countsRaw is Map<Object?, Object?>) {
        for (final ce in countsRaw.entries) {
          if (ce.key is String && ce.value is num) {
            rt.objectiveCounts[ce.key! as String] = (ce.value! as num).toInt();
          }
        }
      }
      _runtime[qId] = rt;
    }
  }
}
