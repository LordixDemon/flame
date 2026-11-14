import 'package:flame/events.dart';
import 'package:flame/extensions.dart';
import 'package:flutter/gestures.dart';

class DoubleTapDownEvent(super.game, TapDownDetails details)
    extends PositionEvent<TapDownDetails> {
  @override
  PointerDeviceKind get deviceKind => raw.kind ?? super.deviceKind;

  this
    : super(
        raw: details,
        devicePosition: details.globalPosition.toVector2(),
      );
}
