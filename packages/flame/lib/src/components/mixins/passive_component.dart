import 'package:flame/src/components/core/component.dart';

/// Marks a [Component] as passive by default (`ticksEnabled == false`), so it
/// remains mounted, rendered, and hit-testable without participating in the
/// per-frame [Component.update] traversal unless explicitly awakened with
/// [Component.wakeUpdates].
mixin PassiveComponent on Component;
