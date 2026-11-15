import 'package:flame/src/rpg/attribute_set.dart';
import 'package:flame/src/rpg/inventory_container.dart';

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
        for (final ins in inserted) {
          bag.removeItem(ins.id);
        }
        bag.addItem(item);
        return false;
      }
    }

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
