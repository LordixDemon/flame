import 'dart:math' as math;

import 'package:flame/src/math/seeded_rng.dart';

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
