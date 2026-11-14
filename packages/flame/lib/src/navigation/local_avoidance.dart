import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

/// Geometric pattern used by [FormationSlots] to arrange co-located tokens,
/// companions, or squad members without visual overlap.
enum FormationPattern() {
  ring,
  centeredRow,
  grid,
  arc,
}

/// Deterministic, zero-allocation slot layout calculator arranging `1 .. N`
/// tokens, companions, or units occupying the same board cell or rally point.
abstract final class FormationSlots._() {
  /// Writes the local `(dx, dy)` offset for `slotIndex` (`0 .. totalCount - 1`)
  /// into [out]. When `totalCount <= 1`, writes `(0, 0)` (except `arc`).
  static void computeSlotOffset({
    required int slotIndex,
    required int totalCount,
    required Vector2 out,
    double radius = 18.0,
    FormationPattern pattern = FormationPattern.ring,
    double startAngleRad = -math.pi / 2,
    double arcSpanRad = math.pi * 0.75,
  }) {
    if (totalCount <= 0) {
      out.setZero();
      return;
    }
    final clampedIdx = slotIndex.clamp(0, totalCount - 1);
    if (totalCount == 1 && pattern != FormationPattern.arc) {
      out.setZero();
      return;
    }

    switch (pattern) {
      case FormationPattern.ring:
        final angle =
            startAngleRad + (clampedIdx / totalCount) * (math.pi * 2.0);
        // Flatten Y slightly (0.72) when used on isometric/2.5D tabletops? Keep
        // isotropic by default; callers can scale Y if desired.
        out.setValues(radius * math.cos(angle), radius * math.sin(angle));
      case FormationPattern.centeredRow:
        final centered = clampedIdx - (totalCount - 1) * 0.5;
        out.setValues(centered * radius, 0.0);
      case FormationPattern.grid:
        final cols = math.sqrt(totalCount).ceil();
        final rows = (totalCount / cols).ceil();
        final col = clampedIdx % cols;
        final row = clampedIdx ~/ cols;
        out.setValues(
          (col - (cols - 1) * 0.5) * radius,
          (row - (rows - 1) * 0.5) * radius,
        );
      case FormationPattern.arc:
        final t = totalCount == 1 ? 0.5 : clampedIdx / (totalCount - 1);
        final angle = startAngleRad - arcSpanRad * 0.5 + arcSpanRad * t;
        out.setValues(radius * math.cos(angle), radius * math.sin(angle));
    }
  }
}

/// Zero-allocation RVO-lite pairwise separation steering solver preventing
/// moving agents from overlapping in corridors or doorways.
abstract final class SeparationSteering2D._() {
  /// Computes a smooth repulsion steering vector pushing `agentPosition` away
  /// from nearby [neighborPositions] within [separationRadius], writing into
  /// [outForce] clamped to [maxForce].
  static void computeSeparation({
    required Vector2 agentPosition,
    required List<Vector2> neighborPositions,
    required double separationRadius,
    required Vector2 outForce,
    double maxForce = 160.0,
  }) {
    outForce.setZero();
    if (separationRadius <= 0.0 || neighborPositions.isEmpty) {
      return;
    }
    final radSq = separationRadius * separationRadius;
    var count = 0;

    for (var i = 0; i < neighborPositions.length; i++) {
      final other = neighborPositions[i];
      if (identical(other, agentPosition)) {
        continue;
      }
      final dx = agentPosition.x - other.x;
      final dy = agentPosition.y - other.y;
      final dSq = dx * dx + dy * dy;
      if (dSq >= radSq) {
        continue;
      }
      count++;
      if (dSq > 1e-8) {
        final d = math.sqrt(dSq);
        final strength = (separationRadius - d) / separationRadius;
        outForce.x += (dx / d) * strength;
        outForce.y += (dy / d) * strength;
      } else {
        // Deterministic symmetry break when two centers coincide exactly.
        final angle = (i + 1) * 2.399963229728653; // Golden angle!
        outForce.x += math.cos(angle);
        outForce.y += math.sin(angle);
      }
    }

    if (count > 0) {
      outForce.scale(maxForce);
      final magSq = outForce.length2;
      if (magSq > maxForce * maxForce) {
        outForce.scale(maxForce / math.sqrt(magSq));
      }
    }
  }
}
