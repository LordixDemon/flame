import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart';

/// Most recently active physical input modality (useful for switching HUD glyph
/// prompts dynamically between touch, keyboard/mouse, and gamepad icons).
enum InputDeviceKind() {
  touch,
  mouseKeyboard,
  gamepad,
}

enum _BindingSource() {
  key,
  mouseButton,
  gamepadButton,
  gamepadAxis,
}

/// Hardware input trigger bound to a named semantic action in [InputMap].
class const ActionBinding._({
  required _BindingSource source,
  this.keyId,
  this.modifiers = const <int>{},
  this.mouseButton,
  this.gamepadControl,
  this.axisPositive = true,
  this.axisThreshold = 0.45,
}) {
  /// Binds a keyboard [key] with optional chord [modifiers] (e.g. Shift, Meta,
  /// Control).
  factory ActionBinding.key(
    LogicalKeyboardKey key, {
    Iterable<LogicalKeyboardKey> modifiers = const <LogicalKeyboardKey>[],
  }) {
    return ActionBinding._(
      source: _BindingSource.key,
      keyId: key.keyId,
      modifiers: <int>{for (final m in modifiers) m.keyId},
    );
  }

  /// Binds a mouse button bitmask (e.g. `1` primary, `2` secondary, `4`
  /// middle).
  const ActionBinding.mouseButton(int button)
    : this._(source: _BindingSource.mouseButton, mouseButton: button);

  /// Binds a named digital gamepad button (e.g. `'south'`, `'east'`,
  /// `'dpad_up'`).
  const ActionBinding.gamepadButton(String buttonId)
    : this._(source: _BindingSource.gamepadButton, gamepadControl: buttonId);

  /// Binds half of an analog gamepad axis (`positive: true` for `+`, `false`
  /// for `-`).
  const ActionBinding.gamepadAxis(
    String axisId, {
    bool positive = true,
    double threshold = 0.45,
  }) : this._(
         source: _BindingSource.gamepadAxis,
         gamepadControl: axisId,
         axisPositive: positive,
         axisThreshold: threshold,
       );

  final _BindingSource _source = source;

  /// `LogicalKeyboardKey.keyId` when bound to a key.
  final int? keyId;

  /// Required chord modifier `keyId`s.
  final Set<int> modifiers;

  /// Pointer button mask when bound to a mouse button.
  final int? mouseButton;

  /// Gamepad button or axis identifier.
  final String? gamepadControl;

  /// Sign of the analog axis trigger.
  final bool axisPositive;

  /// Activation magnitude in `(0.0, 1.0]` for analog axes.
  final double axisThreshold;

  /// Serializes this binding to a JSON-compatible map for user settings saves.
  Map<String, Object?> toJson() => <String, Object?>{
    'source': _source.name,
    if (keyId != null) 'keyId': keyId,
    if (modifiers.isNotEmpty) 'modifiers': modifiers.toList(),
    if (mouseButton != null) 'mouseButton': mouseButton,
    if (gamepadControl != null) 'gamepadControl': gamepadControl,
    'axisPositive': axisPositive,
    'axisThreshold': axisThreshold,
  };

  /// Reconstructs an [ActionBinding] from [toJson].
  factory ActionBinding.fromJson(Map<String, Object?> json) {
    final srcName = json['source'] as String? ?? 'key';
    final src = _BindingSource.values.firstWhere(
      (e) => e.name == srcName,
      orElse: () => _BindingSource.key,
    );
    final rawMods = json['modifiers'];
    final mods = <int>{
      if (rawMods is List)
        for (final item in rawMods)
          if (item is int) item,
    };
    return ActionBinding._(
      source: src,
      keyId: json['keyId'] as int?,
      modifiers: mods,
      mouseButton: json['mouseButton'] as int?,
      gamepadControl: json['gamepadControl'] as String?,
      axisPositive: (json['axisPositive'] as bool?) ?? true,
      axisThreshold: (json['axisThreshold'] as num?)?.toDouble() ?? 0.45,
    );
  }
}

/// Composite 2D directional axis combining four digital actions (`left`,
/// `right`, `up`, `down`) with an optional analog stick pair (`analogAxisX`,
/// `analogAxisY`), radial deadzone, and response curve exponent.
class const InputAxis2D({
  required this.leftAction,
  required this.rightAction,
  required this.upAction,
  required this.downAction,
  this.analogAxisX,
  this.analogAxisY,
  this.deadzone = 0.18,
  this.responseExponent = 1.35,
}) {
  final String leftAction;
  final String rightAction;
  final String upAction;
  final String downAction;
  final String? analogAxisX;
  final String? analogAxisY;

  /// Radial deadzone in `[0.0, 0.9]`.
  final double deadzone;

  /// Power curve (`1.0` = linear, `> 1.0` = finer precision near center).
  final double responseExponent;
}

/// Unified semantic input mapper decoupling game logic from raw keyboard keys,
/// mouse buttons, touch virtual buttons, and gamepad controls, with runtime
/// rebinding, JSON persistence, radial analog deadzones, and active-device
/// detection.
class InputMap({
  InputDeviceKind initialDevice = InputDeviceKind.mouseKeyboard,
}) {
  final Map<String, List<ActionBinding>> _bindings =
      <String, List<ActionBinding>>{};
  final Map<String, InputAxis2D> _axes2d = <String, InputAxis2D>{};

  final Set<int> _heldKeys = <int>{};
  int _heldMouseMask = 0;
  final Set<String> _heldGamepadButtons = <String>{};
  final Map<String, double> _gamepadAxes = <String, double>{};
  final Set<String> _virtualHeldActions = <String>{};

  final Set<String> _prevActiveActions = <String>{};
  final Set<String> _currActiveActions = <String>{};
  final Set<String> _justPressed = <String>{};
  final Set<String> _justReleased = <String>{};

  final ValueNotifier<InputDeviceKind> _deviceNotifier =
      ValueNotifier<InputDeviceKind>(initialDevice);

  /// Reactive notifier updating whenever the player switches between touch,
  /// keyboard/mouse, and gamepad.
  ValueListenable<InputDeviceKind> get activeDeviceListenable =>
      _deviceNotifier;

  /// Most recently used physical input device kind.
  InputDeviceKind get activeDevice => _deviceNotifier.value;

  /// Appends [binding] to semantic [action].
  void bind(String action, ActionBinding binding) {
    (_bindings[action] ??= <ActionBinding>[]).add(binding);
    _recomputeActionNow(action);
  }

  /// Replaces all bindings of [action] with [newBindings].
  void rebind(String action, Iterable<ActionBinding> newBindings) {
    _bindings[action] = List<ActionBinding>.of(newBindings);
    _recomputeActionNow(action);
  }

  /// Removes all bindings registered for [action].
  void clearAction(String action) {
    _bindings.remove(action);
    _currActiveActions.remove(action);
  }

  /// Registers a named 2D directional axis ([InputAxis2D]).
  void registerAxis2D(String axisName, InputAxis2D config) {
    _axes2d[axisName] = config;
  }

  /// Returns an unmodifiable view of bindings for [action].
  List<ActionBinding> bindingsFor(String action) =>
      List<ActionBinding>.unmodifiable(_bindings[action] ?? const []);

  /// Feeds a Flutter [KeyEvent] into the mapper.
  void handleKeyEvent(KeyEvent event) {
    _deviceNotifier.value = InputDeviceKind.mouseKeyboard;
    final id = event.logicalKey.keyId;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _heldKeys.add(id);
    } else if (event is KeyUpEvent) {
      _heldKeys.remove(id);
    }
    _refreshCurrentStates();
  }

  /// Updates the held mouse button bitmask (e.g. from pointer events).
  void setMouseButtonsMask(int buttonsMask) {
    if (_heldMouseMask != buttonsMask) {
      _deviceNotifier.value = InputDeviceKind.mouseKeyboard;
      _heldMouseMask = buttonsMask;
      _refreshCurrentStates();
    }
  }

  /// Triggers or releases a virtual on-screen touch button directly mapped to
  /// [action].
  void setTouchAction(String action, {required bool isDown}) {
    _deviceNotifier.value = InputDeviceKind.touch;
    if (isDown) {
      _virtualHeldActions.add(action);
    } else {
      _virtualHeldActions.remove(action);
    }
    _recomputeActionNow(action);
  }

  /// Updates a digital gamepad button state.
  void setGamepadButton(String buttonId, {required bool isDown}) {
    _deviceNotifier.value = InputDeviceKind.gamepad;
    if (isDown) {
      _heldGamepadButtons.add(buttonId);
    } else {
      _heldGamepadButtons.remove(buttonId);
    }
    _refreshCurrentStates();
  }

  /// Updates a continuous gamepad axis value in `[-1.0, 1.0]`.
  void setGamepadAxis(String axisId, double value) {
    final clamped = value.clamp(-1.0, 1.0);
    if (clamped.abs() > 0.2) {
      _deviceNotifier.value = InputDeviceKind.gamepad;
    }
    _gamepadAxes[axisId] = clamped;
    _refreshCurrentStates();
  }

  /// Releases all currently held keys, mouse buttons, gamepad controls, and
  /// virtual touch actions (essential when an OS window/app loses focus so
  /// inputs never stick held down, firing `justReleased` for active actions).
  void releaseAllInputs() {
    _heldKeys.clear();
    _heldMouseMask = 0;
    _heldGamepadButtons.clear();
    _gamepadAxes.clear();
    _virtualHeldActions.clear();
    _refreshCurrentStates();
  }

  /// Advances edge-triggered `justPressed` / `justReleased` flags at the end of
  /// each simulation frame.
  void endFrame() {
    _justPressed.clear();
    _justReleased.clear();
    _prevActiveActions
      ..clear()
      ..addAll(_currActiveActions);
  }

  /// Whether [action] is currently held down.
  bool isPressed(String action) => _currActiveActions.contains(action);

  /// Whether [action] transitioned from up to down since the previous
  /// [endFrame].
  bool justPressed(String action) => _justPressed.contains(action);

  /// Whether [action] transitioned from down to up since the previous
  /// [endFrame].
  bool justReleased(String action) => _justReleased.contains(action);

  /// Reads a registered [InputAxis2D] into [out] (clamped to unit circle `<= 1`
  /// with radial deadzone and power curve applied to analog sticks).
  void readAxis2D(String axisName, Vector2 out) {
    final cfg = _axes2d[axisName];
    if (cfg == null) {
      out.setZero();
      return;
    }

    var dx = 0.0;
    var dy = 0.0;
    final ax = cfg.analogAxisX;
    final ay = cfg.analogAxisY;
    if (_evaluateAction(cfg.rightAction, ignoreAxisA: ax, ignoreAxisB: ay)) {
      dx += 1.0;
    }
    if (_evaluateAction(cfg.leftAction, ignoreAxisA: ax, ignoreAxisB: ay)) {
      dx -= 1.0;
    }
    if (_evaluateAction(cfg.downAction, ignoreAxisA: ax, ignoreAxisB: ay)) {
      dy += 1.0;
    }
    if (_evaluateAction(cfg.upAction, ignoreAxisA: ax, ignoreAxisB: ay)) {
      dy -= 1.0;
    }

    if (dx != 0.0 || dy != 0.0) {
      out.setValues(dx, dy);
      if (out.length2 > 1.0) {
        out.normalize();
      }
      return;
    }

    final rawX = cfg.analogAxisX != null
        ? (_gamepadAxes[cfg.analogAxisX!] ?? 0.0)
        : 0.0;
    final rawY = cfg.analogAxisY != null
        ? (_gamepadAxes[cfg.analogAxisY!] ?? 0.0)
        : 0.0;
    final mag = math.sqrt(rawX * rawX + rawY * rawY);
    final dz = cfg.deadzone.clamp(0.0, 0.9);
    if (mag <= dz || mag <= 1e-6) {
      out.setZero();
      return;
    }
    final normalizedMag = ((mag - dz) / (1.0 - dz)).clamp(0.0, 1.0);
    final curvedMag = math
        .pow(normalizedMag, cfg.responseExponent)
        .toDouble()
        .clamp(0.0, 1.0);
    final scale = curvedMag / mag;
    out.setValues(rawX * scale, rawY * scale);
  }

  /// Exports all user bindings to a JSON-serializable map.
  Map<String, Object?> exportBindingsJson() => <String, Object?>{
    for (final entry in _bindings.entries)
      entry.key: <Map<String, Object?>>[
        for (final b in entry.value) b.toJson(),
      ],
  };

  /// Restores user bindings from [exportBindingsJson].
  void importBindingsJson(Map<String, Object?> json) {
    for (final entry in json.entries) {
      final list = entry.value;
      if (list is List) {
        _bindings[entry.key] = <ActionBinding>[
          for (final item in list)
            if (item is Map<String, Object?>) ActionBinding.fromJson(item),
        ];
      }
    }
    _refreshCurrentStates();
  }

  /// Releases internal `ValueNotifier` resources.
  void dispose() {
    _deviceNotifier.dispose();
  }

  void _refreshCurrentStates() {
    final allActions = <String>{
      ..._bindings.keys,
      ..._virtualHeldActions,
    };
    for (final action in allActions) {
      _recomputeActionNow(action);
    }
  }

  void _recomputeActionNow(String action) {
    final activeNow = _evaluateAction(action);
    final wasActive = _currActiveActions.contains(action);
    if (activeNow && !wasActive) {
      _currActiveActions.add(action);
      if (!_prevActiveActions.contains(action)) {
        _justPressed.add(action);
      }
      _justReleased.remove(action);
    } else if (!activeNow && wasActive) {
      _currActiveActions.remove(action);
      if (_prevActiveActions.contains(action)) {
        _justReleased.add(action);
      }
      _justPressed.remove(action);
    }
  }

  bool _evaluateAction(
    String action, {
    String? ignoreAxisA,
    String? ignoreAxisB,
  }) {
    if (_virtualHeldActions.contains(action)) {
      return true;
    }
    final list = _bindings[action];
    if (list == null) {
      return false;
    }
    for (var i = 0; i < list.length; i++) {
      final b = list[i];
      if (b._source == _BindingSource.gamepadAxis &&
          (b.gamepadControl == ignoreAxisA ||
              b.gamepadControl == ignoreAxisB)) {
        continue;
      }
      if (_isBindingActive(b)) {
        return true;
      }
    }
    return false;
  }

  bool _isBindingActive(ActionBinding b) {
    switch (b._source) {
      case _BindingSource.key:
        final k = b.keyId;
        if (k == null || !_heldKeys.contains(k)) {
          return false;
        }
        for (final mod in b.modifiers) {
          if (!_heldKeys.contains(mod)) {
            return false;
          }
        }
        return true;
      case _BindingSource.mouseButton:
        final mask = b.mouseButton;
        return mask != null && (_heldMouseMask & mask) != 0;
      case _BindingSource.gamepadButton:
        final ctrl = b.gamepadControl;
        return ctrl != null && _heldGamepadButtons.contains(ctrl);
      case _BindingSource.gamepadAxis:
        final ctrl = b.gamepadControl;
        if (ctrl == null) {
          return false;
        }
        final v = _gamepadAxes[ctrl] ?? 0.0;
        return b.axisPositive ? v >= b.axisThreshold : v <= -b.axisThreshold;
    }
  }
}
