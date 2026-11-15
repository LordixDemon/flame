/// Complete RPG-Maker & Tactical/JRPG gameplay engine suite:
/// - `WorldStateBlackboard` (`SwitchBank`, `VariableBank`, `SelfSwitchStore`,
///   `MapEntityDelta` ledger),
/// - Resumable coroutine `EventFiber` VM, `CommonEvent` call stack, and
///   reactive 5-trigger `EventPageComponent`,
/// - Tile-locked & corner-sliding `GridCharacterMotor`, `MoveRoute`, and
///   zero-allocation `PartyCaterpillarChain`,
/// - `0-1-2-1` `CharacterSpriteSheet` & GPU-cached `PaperDollCompositor`,
/// - GAS `AttributeSet`, `StatusEffectContainer`, and AOT RPN `FormulaVM`,
/// - Round / Wait-ATB / CTB `TurnTimelineScheduler` with side-effect-free
///   `previewTurnOrder`,
/// - Pity-protected `LootTable`, two-handed-mutex `EquipmentLoadout` with
///   `previewEquipStatDiff`, and DAG `QuestJournalMachine`.
library;

export 'src/rpg/attributes_and_formula_vm.dart';
export 'src/rpg/event_interpreter.dart';
export 'src/rpg/grid_character_and_caterpillar.dart';
export 'src/rpg/inventory_loot_and_quests.dart';
export 'src/rpg/paper_doll_and_sheet.dart';
export 'src/rpg/turn_timeline_scheduler.dart';
export 'src/rpg/world_state_blackboard.dart';
