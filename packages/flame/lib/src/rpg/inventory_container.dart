import 'dart:math' as math;

import 'package:flame/src/rpg/attribute_set.dart';

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

  /// Allowed equipment slot, or `null` for non-equippable consumables/key
  /// items.
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
