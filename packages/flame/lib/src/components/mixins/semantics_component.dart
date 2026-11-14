import 'package:flame/components.dart';
import 'package:flutter/rendering.dart';

/// Mixin exposing a Flame [Component] (in `FlameGame`,
/// `CameraComponent.viewport` HUD, or `CameraComponent.world`) to Flutter's OS
/// accessibility tree (`SemanticsNode` — Apple VoiceOver, Android TalkBack, Web
/// ARIA, and `WidgetTester` semantics finders).
///
/// Any mutation to a `semantics*` property or callback automatically notifies
/// `Game.markNeedsSemantics()` so `GameRenderBox.assembleSemanticsNode`
/// updates the retained [SemanticsNode] on the next frame without rebuilding
/// `GameWidget`.
mixin SemanticsComponent on Component {
  /// Number of [SemanticsComponent] instances currently mounted across active
  /// component trees.
  static int get mountedCount => _mountedCount;
  static int _mountedCount = 0;

  bool _semanticsEnabled = true;
  bool _semanticsExcluded = false;
  String? _semanticsLabel;
  String? _semanticsValue;
  String? _semanticsIncreasedValue;
  String? _semanticsDecreasedValue;
  String? _semanticsHint;
  String? _semanticsTooltip;
  bool _isSemanticsButton = false;
  bool _isSemanticsFocusable = false;
  bool _isSemanticsFocused = false;
  bool? _isSemanticsChecked;
  bool _isSemanticsSelected = false;
  bool _isSemanticsHeader = false;
  bool _isSemanticsLiveRegion = false;
  bool _isSemanticsReadOnly = false;
  double? _semanticsSortOrder;
  Rect? _semanticsLocalBounds;

  VoidCallback? _onSemanticsTap;
  VoidCallback? _onSemanticsLongPress;
  VoidCallback? _onSemanticsIncrease;
  VoidCallback? _onSemanticsDecrease;
  VoidCallback? _onSemanticsFocus;
  VoidCallback? _onSemanticsDismiss;

  void _notifySemanticsChanged() {
    if (isMounted) {
      findGame()?.markNeedsSemantics();
    }
  }

  /// Whether this component's accessibility actions are enabled (`false`
  /// exposes `isEnabled = false` and suppresses action callbacks while keeping
  /// the node visible to assistive technology).
  bool get semanticsEnabled => _semanticsEnabled;
  set semanticsEnabled(bool value) {
    if (_semanticsEnabled != value) {
      _semanticsEnabled = value;
      _notifySemanticsChanged();
    }
  }

  /// Whether to completely omit this component from the accessibility tree
  /// (analogous to Flutter's `ExcludeSemantics`).
  bool get semanticsExcluded => _semanticsExcluded;
  set semanticsExcluded(bool value) {
    if (_semanticsExcluded != value) {
      _semanticsExcluded = value;
      _notifySemanticsChanged();
    }
  }

  /// Primary human-readable label announced by screen readers.
  String? get semanticsLabel => _semanticsLabel;
  set semanticsLabel(String? value) {
    if (_semanticsLabel != value) {
      _semanticsLabel = value;
      _notifySemanticsChanged();
    }
  }

  /// Dynamic current value (e.g. `'75%'`, `'1,250 coins'`).
  String? get semanticsValue => _semanticsValue;
  set semanticsValue(String? value) {
    if (_semanticsValue != value) {
      _semanticsValue = value;
      _notifySemanticsChanged();
    }
  }

  /// Optional preview value announced for `SemanticsAction.increase` (defaults
  /// to [semanticsValue] when [onSemanticsIncrease] and [semanticsValue] are
  /// both set).
  String? get semanticsIncreasedValue => _semanticsIncreasedValue;
  set semanticsIncreasedValue(String? value) {
    if (_semanticsIncreasedValue != value) {
      _semanticsIncreasedValue = value;
      _notifySemanticsChanged();
    }
  }

  /// Optional preview value announced for `SemanticsAction.decrease` (defaults
  /// to [semanticsValue] when [onSemanticsDecrease] and [semanticsValue] are
  /// both set).
  String? get semanticsDecreasedValue => _semanticsDecreasedValue;
  set semanticsDecreasedValue(String? value) {
    if (_semanticsDecreasedValue != value) {
      _semanticsDecreasedValue = value;
      _notifySemanticsChanged();
    }
  }

  /// Action hint announced after label/value (e.g. `'Double tap to roll dice'`).
  String? get semanticsHint => _semanticsHint;
  set semanticsHint(String? value) {
    if (_semanticsHint != value) {
      _semanticsHint = value;
      _notifySemanticsChanged();
    }
  }

  /// Optional tooltip string exposed to assistive technology.
  String? get semanticsTooltip => _semanticsTooltip;
  set semanticsTooltip(String? value) {
    if (_semanticsTooltip != value) {
      _semanticsTooltip = value;
      _notifySemanticsChanged();
    }
  }

  /// Marks this node with button semantics.
  bool get isSemanticsButton => _isSemanticsButton;
  set isSemanticsButton(bool value) {
    if (_isSemanticsButton != value) {
      _isSemanticsButton = value;
      _notifySemanticsChanged();
    }
  }

  /// Marks this node as focusable by assistive navigation.
  bool get isSemanticsFocusable => _isSemanticsFocusable;
  set isSemanticsFocusable(bool value) {
    if (_isSemanticsFocusable != value) {
      _isSemanticsFocusable = value;
      _notifySemanticsChanged();
    }
  }

  /// Whether this node currently holds accessibility focus.
  bool get isSemanticsFocused => _isSemanticsFocused;
  set isSemanticsFocused(bool value) {
    if (_isSemanticsFocused != value) {
      _isSemanticsFocused = value;
      _notifySemanticsChanged();
    }
  }

  /// Optional checkbox/toggle state (`null` when not checkable).
  bool? get isSemanticsChecked => _isSemanticsChecked;
  set isSemanticsChecked(bool? value) {
    if (_isSemanticsChecked != value) {
      _isSemanticsChecked = value;
      _notifySemanticsChanged();
    }
  }

  /// Whether this node is currently selected (e.g. active tab or board tile).
  bool get isSemanticsSelected => _isSemanticsSelected;
  set isSemanticsSelected(bool value) {
    if (_isSemanticsSelected != value) {
      _isSemanticsSelected = value;
      _notifySemanticsChanged();
    }
  }

  /// Marks this node as a section header.
  bool get isSemanticsHeader => _isSemanticsHeader;
  set isSemanticsHeader(bool value) {
    if (_isSemanticsHeader != value) {
      _isSemanticsHeader = value;
      _notifySemanticsChanged();
    }
  }

  /// Marks this node as a live region so dynamic [semanticsLabel] /
  /// [semanticsValue] changes are announced politely.
  bool get isSemanticsLiveRegion => _isSemanticsLiveRegion;
  set isSemanticsLiveRegion(bool value) {
    if (_isSemanticsLiveRegion != value) {
      _isSemanticsLiveRegion = value;
      _notifySemanticsChanged();
    }
  }

  /// Marks this node as read-only.
  bool get isSemanticsReadOnly => _isSemanticsReadOnly;
  set isSemanticsReadOnly(bool value) {
    if (_isSemanticsReadOnly != value) {
      _isSemanticsReadOnly = value;
      _notifySemanticsChanged();
    }
  }

  /// Optional explicit traversal sort order (`OrdinalSortKey`).
  double? get semanticsSortOrder => _semanticsSortOrder;
  set semanticsSortOrder(double? value) {
    if (_semanticsSortOrder != value) {
      _semanticsSortOrder = value;
      _notifySemanticsChanged();
    }
  }

  /// Optional local-space bounding rectangle override (defaults to
  /// `Offset.zero & size` on [PositionComponent]s).
  Rect? get semanticsLocalBounds => _semanticsLocalBounds;
  set semanticsLocalBounds(Rect? value) {
    if (_semanticsLocalBounds != value) {
      _semanticsLocalBounds = value;
      _notifySemanticsChanged();
    }
  }

  /// Assistive tap activation callback.
  VoidCallback? get onSemanticsTap => _onSemanticsTap;
  set onSemanticsTap(VoidCallback? value) {
    if (_onSemanticsTap != value) {
      _onSemanticsTap = value;
      _notifySemanticsChanged();
    }
  }

  /// Assistive long-press activation callback.
  VoidCallback? get onSemanticsLongPress => _onSemanticsLongPress;
  set onSemanticsLongPress(VoidCallback? value) {
    if (_onSemanticsLongPress != value) {
      _onSemanticsLongPress = value;
      _notifySemanticsChanged();
    }
  }

  /// Assistive increment callback (sliders / steppers).
  VoidCallback? get onSemanticsIncrease => _onSemanticsIncrease;
  set onSemanticsIncrease(VoidCallback? value) {
    if (_onSemanticsIncrease != value) {
      _onSemanticsIncrease = value;
      _notifySemanticsChanged();
    }
  }

  /// Assistive decrement callback (sliders / steppers).
  VoidCallback? get onSemanticsDecrease => _onSemanticsDecrease;
  set onSemanticsDecrease(VoidCallback? value) {
    if (_onSemanticsDecrease != value) {
      _onSemanticsDecrease = value;
      _notifySemanticsChanged();
    }
  }

  /// Assistive focus request callback.
  VoidCallback? get onSemanticsFocus => _onSemanticsFocus;
  set onSemanticsFocus(VoidCallback? value) {
    if (_onSemanticsFocus != value) {
      _onSemanticsFocus = value;
      _notifySemanticsChanged();
    }
  }

  /// Assistive dismiss callback (modals / tooltips).
  VoidCallback? get onSemanticsDismiss => _onSemanticsDismiss;
  set onSemanticsDismiss(VoidCallback? value) {
    if (_onSemanticsDismiss != value) {
      _onSemanticsDismiss = value;
      _notifySemanticsChanged();
    }
  }

  /// Builds a Flutter [SemanticsConfiguration] representing this component's
  /// current accessibility state.
  SemanticsConfiguration buildSemanticsConfiguration({
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final config = SemanticsConfiguration()
      ..isSemanticBoundary = true
      ..isEnabled = _semanticsEnabled
      ..textDirection = textDirection;

    if (_semanticsLabel != null) {
      config.label = _semanticsLabel!;
    }
    if (_semanticsValue != null) {
      config.value = _semanticsValue!;
    }
    if (_semanticsHint != null) {
      config.hint = _semanticsHint!;
    }
    if (_semanticsTooltip != null) {
      config.tooltip = _semanticsTooltip!;
    }
    if (_isSemanticsButton) {
      config.isButton = true;
    }
    if (_isSemanticsFocusable || _isSemanticsFocused) {
      config.isFocused = _isSemanticsFocused;
    }
    if (_isSemanticsChecked != null) {
      config.isChecked = _isSemanticsChecked;
    }
    if (_isSemanticsSelected) {
      config.isSelected = true;
    }
    if (_isSemanticsHeader) {
      config.isHeader = true;
    }
    if (_isSemanticsLiveRegion) {
      config.liveRegion = true;
    }
    if (_isSemanticsReadOnly) {
      config.isReadOnly = true;
    }
    if (_semanticsSortOrder != null) {
      config.sortKey = OrdinalSortKey(_semanticsSortOrder!);
    }

    if (_semanticsEnabled) {
      if (_onSemanticsTap != null) {
        config.onTap = _onSemanticsTap;
      }
      if (_onSemanticsLongPress != null) {
        config.onLongPress = _onSemanticsLongPress;
      }
      if (_onSemanticsIncrease != null) {
        config.onIncrease = _onSemanticsIncrease;
        final inc = _semanticsIncreasedValue;
        if (inc != null) {
          config.increasedValue = inc;
        } else if (config.value.isNotEmpty) {
          config.increasedValue = config.value;
        }
      }
      if (_onSemanticsDecrease != null) {
        config.onDecrease = _onSemanticsDecrease;
        final dec = _semanticsDecreasedValue;
        if (dec != null) {
          config.decreasedValue = dec;
        } else if (config.value.isNotEmpty) {
          config.decreasedValue = config.value;
        }
      }
      if (_onSemanticsFocus != null) {
        config.onFocus = _onSemanticsFocus;
      }
      if (_onSemanticsDismiss != null) {
        config.onDismiss = _onSemanticsDismiss;
      }
    }
    return config;
  }

  @override
  void onMount() {
    super.onMount();
    _mountedCount++;
    findGame()?.markNeedsSemantics();
  }

  @override
  void onRemove() {
    if (_mountedCount > 0) {
      _mountedCount--;
    }
    findGame()?.markNeedsSemantics();
    super.onRemove();
  }
}
