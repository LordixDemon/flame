import 'dart:math' as math;

import 'package:flame/src/components/core/event_bus.dart';
import 'package:flame/src/math/seeded_rng.dart';
import 'package:flame/src/rpg/attributes_and_formula_vm.dart';

// ============================================================================
// 1. Weighted Loot Tables with Pity / Bad-Luck Protection & Unique Exclusions
// ============================================================================

/// Result roll produced by [LootTable.roll].
class const LootDrop<T>({
  required this.item,
  required this.quantity,
  this.triggeredPity = false,
}) {
  /// Dropped reward payload.
  final T item;

  /// Dropped stack count (`>= 1`).
  final int quantity;

  /// `true` if this drop was forced by reaching [LootTable.pityThreshold].
  final bool triggeredPity;
}

/// Mutable bad-luck protection state persisted across [LootTable.roll] calls.
class LootPityTracker({int initialMissStreak = 0}) {
  /// Consecutive rolls without hitting any `isRarePityTarget` entry.
  int rollsSinceRare = math.max(0, initialMissStreak);
}

/// Weighted entry or nested sub-table inside a [LootTable].
class LootEntry<T> {
  /// Creates a direct item drop entry.
  const LootEntry.item({
    required T this.item,
    required this.weight,
    this.minQuantity = 1,
    this.maxQuantity = 1,
    this.isRarePityTarget = false,
    this.uniqueKey,
    this.condition,
  }) : subTable = null,
       assert(weight >= 0.0, 'weight must be >= 0.'),
       assert(minQuantity >= 1 && maxQuantity >= minQuantity, 'Invalid qty.');

  /// Creates a nested sub-table branch entry.
  const LootEntry.subTable({
    required LootTable<T> this.subTable,
    required this.weight,
    this.isRarePityTarget = false,
    this.condition,
  }) : item = null,
       minQuantity = 1,
       maxQuantity = 1,
       uniqueKey = null,
       assert(weight >= 0.0, 'weight must be >= 0.');

  /// Direct item payload (when `subTable == null`).
  final T? item;

  /// Nested sub-table (when `item == null`).
  final LootTable<T>? subTable;

  /// Relative selection weight (`> 0` to be rolled naturally).
  final double weight;

  /// Minimum stack quantity rolled inclusively.
  final int minQuantity;

  /// Maximum stack quantity rolled inclusively.
  final int maxQuantity;

  /// Whether this entry qualifies for bad-luck protection (`pityThreshold`)
  /// and resets [LootPityTracker.rollsSinceRare] when dropped.
  final bool isRarePityTarget;

  /// Optional unique key skipped if already present in `excludedUniqueKeys`.
  final String? uniqueKey;

  /// Optional runtime predicate gating eligibility (e.g. quest active).
  final bool Function()? condition;
}

/// Deterministic weighted drop table supporting nested sub-tables, unique item
/// exclusions, and guaranteed rare pity drops at [pityThreshold].
class LootTable<T>({
  required List<LootEntry<T>> entries,
  this.nothingWeight = 0.0,
  this.pityThreshold = 0,
}) {
  this
    : assert(nothingWeight >= 0.0, 'nothingWeight must be >= 0.'),
      assert(pityThreshold >= 0, 'pityThreshold must be >= 0.');

  final List<LootEntry<T>> _entries = List<LootEntry<T>>.unmodifiable(entries);

  /// Weight assigned to rolling "no drop" (`null`).
  final double nothingWeight;

  /// When `> 0`, forces a rare (`isRarePityTarget: true`) entry on the N-th
  /// consecutive roll if the previous `N - 1` rolls did not yield one.
  final int pityThreshold;

  final LootPityTracker _internalPity = LootPityTracker();

  /// Built-in pity tracker used when no external tracker is supplied to [roll].
  LootPityTracker get internalPity => _internalPity;

  /// Executes one deterministic loot roll using [rng].
  LootDrop<T>? roll(
    SeededRng rng, {
    LootPityTracker? pityTracker,
    Set<String>? excludedUniqueKeys,
    int maxDepth = 8,
  }) => _rollInternal(
    rng,
    pity: pityTracker ?? _internalPity,
    excluded: excludedUniqueKeys,
    depth: 0,
    maxDepth: maxDepth,
  );

  LootDrop<T>? _rollInternal(
    SeededRng rng, {
    required LootPityTracker pity,
    required Set<String>? excluded,
    required int depth,
    required int maxDepth,
  }) {
    if (depth > maxDepth || _entries.isEmpty) {
      return null;
    }

    bool isEligible(LootEntry<T> e) {
      if (e.uniqueKey != null && (excluded?.contains(e.uniqueKey) ?? false)) {
        return false;
      }
      if (e.condition != null && !e.condition!()) {
        return false;
      }
      return true;
    }

    final forcePity =
        depth == 0 &&
        pityThreshold > 0 &&
        (pity.rollsSinceRare + 1) >= pityThreshold;

    if (forcePity) {
      final rareCandidates = _entries
          .where((e) => e.isRarePityTarget && isEligible(e))
          .toList();
      if (rareCandidates.isNotEmpty) {
        final picked = _pickWeighted(rng, rareCandidates, extraNothing: 0.0);
        if (picked != null) {
          pity.rollsSinceRare = 0;
          return _resolvePicked(
            picked,
            rng: rng,
            pity: pity,
            excluded: excluded,
            depth: depth,
            maxDepth: maxDepth,
            triggeredPity: true,
          );
        }
      }
    }

    final eligible = _entries
        .where((e) => e.weight > 0.0 && isEligible(e))
        .toList();
    final picked = _pickWeighted(
      rng,
      eligible,
      extraNothing: depth == 0 ? nothingWeight : 0.0,
    );

    if (picked == null) {
      if (depth == 0 && pityThreshold > 0) {
        pity.rollsSinceRare++;
      }
      return null;
    }

    if (depth == 0 && pityThreshold > 0) {
      if (picked.isRarePityTarget) {
        pity.rollsSinceRare = 0;
      } else {
        pity.rollsSinceRare++;
      }
    }

    return _resolvePicked(
      picked,
      rng: rng,
      pity: pity,
      excluded: excluded,
      depth: depth,
      maxDepth: maxDepth,
      triggeredPity: false,
    );
  }

  LootDrop<T>? _resolvePicked(
    LootEntry<T> picked, {
    required SeededRng rng,
    required LootPityTracker pity,
    required Set<String>? excluded,
    required int depth,
    required int maxDepth,
    required bool triggeredPity,
  }) {
    final sub = picked.subTable;
    if (sub != null) {
      final nested = sub._rollInternal(
        rng,
        pity: pity,
        excluded: excluded,
        depth: depth + 1,
        maxDepth: maxDepth,
      );
      if (nested == null) {
        return null;
      }
      return LootDrop<T>(
        item: nested.item,
        quantity: nested.quantity,
        triggeredPity: triggeredPity || nested.triggeredPity,
      );
    }

    final val = picked.item as T;
    final span = picked.maxQuantity - picked.minQuantity;
    final qty = span <= 0
        ? picked.minQuantity
        : picked.minQuantity + rng.nextInt(span + 1);
    return LootDrop<T>(
      item: val,
      quantity: qty,
      triggeredPity: triggeredPity,
    );
  }

  static LootEntry<T>? _pickWeighted<T>(
    SeededRng rng,
    List<LootEntry<T>> candidates, {
    required double extraNothing,
  }) {
    var total = extraNothing;
    for (var i = 0; i < candidates.length; i++) {
      total += math.max(0.0, candidates[i].weight);
    }
    if (total <= 0.0) {
      // Equal probability fallback when rare pity forces a 0-weight jackpot!
      if (candidates.isEmpty) {
        return null;
      }
      return candidates[rng.nextInt(candidates.length)];
    }
    var ticket = rng.nextDouble() * total;
    for (var i = 0; i < candidates.length; i++) {
      final w = math.max(0.0, candidates[i].weight);
      if (ticket < w) {
        return candidates[i];
      }
      ticket -= w;
    }
    return null;
  }
}

// ============================================================================
// 2. Inventory Container & Equipment Loadout (Two-Handed Mutex + Stat Preview)
// ============================================================================

/// Standard RPG equipment slots.
enum EquipSlot() {
  /// Primary weapon hand.
  mainHand,

  /// Shield, parrying dagger, or tome hand (mutually exclusive with two-handed
  /// `mainHand` weapons).
  offHand,

  /// Helmet, circlet, or hat.
  head,

  /// Chest armor or robe.
  body,

  /// Greaves or boots.
  legs,

  /// First ring/relic slot.
  accessory1,

  /// Second ring/relic slot.
  accessory2,
}

/// Static definition of an inventory/equipment item.
class const InventoryItemDef({
  required this.id,
  required this.name,
  this.maxStack = 99,
  this.unitWeight = 0.0,
  this.rarity = 0,
  this.sortCategory = 0,
  this.equipSlot,
  this.twoHanded = false,
  this.statModifiers = const <StatModifier>[],
}) {
  this
    : assert(maxStack >= 1, 'maxStack must be >= 1.'),
      assert(unitWeight >= 0.0, 'unitWeight must be >= 0.');

  /// Unique database item ID.
  final String id;

  /// Display name.
  final String name;

  /// Maximum stack count per inventory slot (`1` for unique gear).
  final int maxStack;

  /// Encumbrance weight per unit.
  final double unitWeight;

  /// Rarity tier (`0` common .. `5` mythic) used for sorting.
  final int rarity;

  /// Category order used for inventory sorting.
  final int sortCategory;

  /// Allowed equipment slot, or `null` for non-equippable consumables/key items.
  final EquipSlot? equipSlot;

  /// When `true` on a [EquipSlot.mainHand] weapon, equipping it automatically
  /// unequips [EquipSlot.offHand] (and equipping an [EquipSlot.offHand] item
  /// unequips the two-handed weapon).
  final bool twoHanded;

  /// Attribute modifiers granted while equipped.
  final List<StatModifier> statModifiers;
}

/// Live item stack occupying one slot in [InventoryContainer].
class ItemStack(this.item, this.quantity) {
  this : assert(quantity >= 1, 'Stack quantity must be >= 1.');

  /// Item definition.
  final InventoryItemDef item;

  /// Stack count (`1 .. item.maxStack`).
  int quantity;

  /// Total weight of this stack.
  double get stackWeight => item.unitWeight * quantity;
}

/// Slot- and weight-bounded RPG inventory with stack merging, splitting, and
/// deterministic sorting.
class InventoryContainer({
  this.maxSlots = 40,
  this.maxWeight = double.infinity,
}) {
  this
    : assert(maxSlots >= 1, 'maxSlots must be >= 1.'),
      assert(maxWeight >= 0.0, 'maxWeight must be >= 0.');

  /// Maximum occupied [ItemStack] slots.
  final int maxSlots;

  /// Maximum carried weight (`double.infinity` = weightless JRPG bag).
  final double maxWeight;

  final List<ItemStack> _slots = <ItemStack>[];

  /// Read-only view of occupied slots.
  List<ItemStack> get slots => List<ItemStack>.unmodifiable(_slots);

  /// Number of occupied slots.
  int get usedSlots => _slots.length;

  /// Remaining free slots.
  int get freeSlots => math.max(0, maxSlots - _slots.length);

  /// Total encumbrance weight across all carried stacks.
  double get totalWeight {
    var sum = 0.0;
    for (var i = 0; i < _slots.length; i++) {
      sum += _slots[i].stackWeight;
    }
    return sum;
  }

  /// Total quantity of [itemId] across all stacks.
  int countOf(String itemId) {
    var sum = 0;
    for (var i = 0; i < _slots.length; i++) {
      if (_slots[i].item.id == itemId) {
        sum += _slots[i].quantity;
      }
    }
    return sum;
  }

  /// Returns `true` if ALL [quantity] units of [item] can fit within both
  /// [maxSlots] and [maxWeight].
  bool canFitAll(InventoryItemDef item, int quantity) {
    if (quantity <= 0) {
      return true;
    }
    if (totalWeight + item.unitWeight * quantity > maxWeight + 1e-9) {
      return false;
    }
    var remaining = quantity;
    for (var i = 0; i < _slots.length && remaining > 0; i++) {
      if (_slots[i].item.id == item.id && _slots[i].quantity < item.maxStack) {
        remaining -= item.maxStack - _slots[i].quantity;
      }
    }
    if (remaining <= 0) {
      return true;
    }
    final neededNewSlots = (remaining + item.maxStack - 1) ~/ item.maxStack;
    return neededNewSlots <= freeSlots;
  }

  /// Adds up to [quantity] units of [item], merging into partial stacks first
  /// and returning the **leftover count** (`0` if everything fit).
  int addItem(InventoryItemDef item, [int quantity = 1]) {
    if (quantity <= 0) {
      return 0;
    }
    var remaining = quantity;

    // Respect weight cap first.
    if (item.unitWeight > 0.0 && maxWeight.isFinite) {
      final availWeight = math.max(0.0, maxWeight - totalWeight);
      final maxByWeight = (availWeight / item.unitWeight + 1e-9).floor();
      final fit = math.min(remaining, maxByWeight);
      final rejectedByWeight = remaining - fit;
      remaining = fit;
      if (remaining <= 0) {
        return quantity;
      }
      final leftoverFromSlots = _insertUnits(item, remaining);
      return rejectedByWeight + leftoverFromSlots;
    }

    return _insertUnits(item, remaining);
  }

  int _insertUnits(InventoryItemDef item, int count) {
    var remaining = count;
    for (var i = 0; i < _slots.length && remaining > 0; i++) {
      final s = _slots[i];
      if (s.item.id == item.id && s.quantity < item.maxStack) {
        final add = math.min(remaining, item.maxStack - s.quantity);
        s.quantity += add;
        remaining -= add;
      }
    }
    while (remaining > 0 && _slots.length < maxSlots) {
      final add = math.min(remaining, item.maxStack);
      _slots.add(ItemStack(item, add));
      remaining -= add;
    }
    return remaining;
  }

  /// Removes up to [quantity] units of [itemId], returning the actual count
  /// removed.
  int removeItem(String itemId, [int quantity = 1]) {
    if (quantity <= 0) {
      return 0;
    }
    var remaining = quantity;
    for (var i = _slots.length - 1; i >= 0 && remaining > 0; i--) {
      final s = _slots[i];
      if (s.item.id != itemId) {
        continue;
      }
      if (s.quantity <= remaining) {
        remaining -= s.quantity;
        _slots.removeAt(i);
      } else {
        s.quantity -= remaining;
        remaining = 0;
      }
    }
    return quantity - remaining;
  }

  /// Compacts partial stacks and sorts items by `(sortCategory, -rarity, id)`.
  void compactAndSort() {
    final merged = <String, int>{};
    final defs = <String, InventoryItemDef>{};
    for (final s in _slots) {
      defs[s.item.id] = s.item;
      merged[s.item.id] = (merged[s.item.id] ?? 0) + s.quantity;
    }
    final orderedIds = defs.keys.toList()
      ..sort((a, b) {
        final da = defs[a]!;
        final db = defs[b]!;
        final cat = da.sortCategory.compareTo(db.sortCategory);
        if (cat != 0) {
          return cat;
        }
        final rar = db.rarity.compareTo(da.rarity);
        if (rar != 0) {
          return rar;
        }
        return da.id.compareTo(db.id);
      });
    _slots.clear();
    for (final id in orderedIds) {
      final def = defs[id]!;
      var rem = merged[id]!;
      while (rem > 0) {
        final take = math.min(rem, def.maxStack);
        _slots.add(ItemStack(def, take));
        rem -= take;
      }
    }
  }
}

/// Character equipment loadout enforcing slot compatibility, atomic two-handed
/// weapon / offhand shield mutual exclusion, live [AttributeSet] modifier
/// synchronization, and side-effect-free `previewEquipStatDiff`.
class EquipmentLoadout(this.attributes) {
  /// Character [AttributeSet] receiving equipped item modifiers.
  final AttributeSet attributes;

  final Map<EquipSlot, InventoryItemDef> _equipped =
      <EquipSlot, InventoryItemDef>{};

  /// Queries the item currently equipped in [slot], or `null`.
  InventoryItemDef? equippedIn(EquipSlot slot) => _equipped[slot];

  /// Whether a two-handed weapon is currently occupying [EquipSlot.mainHand].
  bool get isTwoHandedEquipped =>
      _equipped[EquipSlot.mainHand]?.twoHanded ?? false;

  static bool _isSlotCompatible(EquipSlot targetSlot, InventoryItemDef item) {
    final allowed = item.equipSlot;
    if (allowed == null) {
      return false;
    }
    if (allowed == targetSlot) {
      return true;
    }
    // Allow accessory1 definitions to fit in either accessory1 or accessory2.
    if ((allowed == EquipSlot.accessory1 || allowed == EquipSlot.accessory2) &&
        (targetSlot == EquipSlot.accessory1 ||
            targetSlot == EquipSlot.accessory2)) {
      return true;
    }
    return false;
  }

  /// Equips `1` unit of [item] into [slot] (optionally pulling from and
  /// returning displaced gear into [bag]).
  ///
  /// Enforces atomic two-handed mutex:
  /// - Equipping a `twoHanded` weapon into `mainHand` automatically unequips
  ///   both the previous `mainHand` AND any `offHand` shield into [bag]
  ///   (failing without partial state mutation if [bag] lacks space for both!).
  /// - Equipping an `offHand` item while a `twoHanded` weapon is equipped
  ///   automatically unequips the `twoHanded` weapon into [bag].
  bool equip(
    EquipSlot slot,
    InventoryItemDef item, {
    InventoryContainer? bag,
  }) {
    if (!_isSlotCompatible(slot, item)) {
      return false;
    }
    if (bag != null && bag.countOf(item.id) < 1) {
      return false;
    }

    final displaced = <InventoryItemDef>[];
    final prevInSlot = _equipped[slot];
    if (prevInSlot != null) {
      displaced.add(prevInSlot);
    }
    if (slot == EquipSlot.mainHand && item.twoHanded) {
      final off = _equipped[EquipSlot.offHand];
      if (off != null) {
        displaced.add(off);
      }
    } else if (slot == EquipSlot.offHand && isTwoHandedEquipped) {
      final main = _equipped[EquipSlot.mainHand];
      if (main != null) {
        displaced.add(main);
      }
    }

    if (bag != null) {
      // Take the candidate item out temporarily so its freed slot can hold
      // displaced gear!
      bag.removeItem(item.id);
      var allFit = true;
      final inserted = <InventoryItemDef>[];
      for (final old in displaced) {
        if (!bag.canFitAll(old, 1)) {
          allFit = false;
          break;
        }
        bag.addItem(old);
        inserted.add(old);
      }
      if (!allFit) {
        // Roll back atomically!
        for (final ins in inserted) {
          bag.removeItem(ins.id);
        }
        bag.addItem(item);
        return false;
      }
    }

    // Commit equipment state & sync AttributeSet modifiers.
    if (slot == EquipSlot.mainHand && item.twoHanded) {
      _clearSlot(EquipSlot.offHand);
    } else if (slot == EquipSlot.offHand && isTwoHandedEquipped) {
      _clearSlot(EquipSlot.mainHand);
    }
    _setSlot(slot, item);
    return true;
  }

  /// Unequips [slot] (returning the item to [bag] if provided).
  bool unequip(EquipSlot slot, {InventoryContainer? bag}) {
    final existing = _equipped[slot];
    if (existing == null) {
      return false;
    }
    if (bag != null && !bag.canFitAll(existing, 1)) {
      return false;
    }
    _clearSlot(slot);
    bag?.addItem(existing);
    return true;
  }

  /// Computes the exact stat deltas (`candidateValue - currentValue`) across
  /// [statIds] if [candidateItem] (`null` = unequip) were placed into [slot],
  /// **including** automatic two-handed/offhand unequip side effects, without
  /// mutating live equipment or [attributes].
  Map<String, double> previewEquipStatDiff(
    EquipSlot slot,
    InventoryItemDef? candidateItem, {
    Iterable<String>? statIds,
  }) {
    if (candidateItem != null && !_isSlotCompatible(slot, candidateItem)) {
      return const <String, double>{};
    }

    final simAttrs = attributes.clone();
    final simLoadout = EquipmentLoadout(simAttrs);
    simLoadout._equipped.addAll(_equipped);

    if (candidateItem == null) {
      simLoadout._clearSlot(slot);
    } else {
      if (slot == EquipSlot.mainHand && candidateItem.twoHanded) {
        simLoadout._clearSlot(EquipSlot.offHand);
      } else if (slot == EquipSlot.offHand && simLoadout.isTwoHandedEquipped) {
        simLoadout._clearSlot(EquipSlot.mainHand);
      }
      simLoadout._setSlot(slot, candidateItem);
    }

    final keys =
        statIds ?? <String>{...attributes.statIds, ...simAttrs.statIds};
    final diffs = <String, double>{};
    for (final key in keys) {
      final before = attributes.get(key);
      final after = simAttrs.get(key);
      final delta = after - before;
      if (delta.abs() > 1e-9) {
        diffs[key] = delta;
      }
    }
    return diffs;
  }

  static String _slotSourceKey(EquipSlot slot) => 'equip:${slot.name}';

  void _clearSlot(EquipSlot slot) {
    _equipped.remove(slot);
    attributes.removeModifiersBySource(_slotSourceKey(slot));
  }

  void _setSlot(EquipSlot slot, InventoryItemDef item) {
    final src = _slotSourceKey(slot);
    attributes.removeModifiersBySource(src);
    _equipped[slot] = item;
    for (var i = 0; i < item.statModifiers.length; i++) {
      final m = item.statModifiers[i];
      attributes.addModifier(
        StatModifier(
          id: '$src:$i:${m.id}',
          statId: m.statId,
          op: m.op,
          value: m.value,
          sourceId: src,
          priority: m.priority,
        ),
      );
    }
  }
}

// ============================================================================
// 3. Quest Journal DAG Machine (allOf / anyOf / sequential + Failure Branches)
// ============================================================================

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
    // `startQuest` (e.g. unlocking the next quest in a chain) without throwing
    // `ConcurrentModificationError`!
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

      // 1. Check stage failure trigger first!
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

      // 2. Advance matching objective(s) according to stage mode!
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
          // Sequential mode strictly blocks advancing later objectives until
          // this first incomplete objective finishes!
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

      // 3. Check if stage completed!
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
