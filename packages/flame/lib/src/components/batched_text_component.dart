import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/src/effects/provider_interfaces.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';

/// Lightweight GPU-batched text component backed by a [RasterFontAtlas].
///
/// Updates to [text], [color], or [opacity] perform zero `Paragraph` layout
/// allocations. When added inside a [GlyphBatchLayer], all sibling
/// [BatchedTextComponent]s sharing the same [atlas] are merged into a single
/// `Canvas.drawRawAtlas` call per frame.
class BatchedTextComponent({
  required RasterFontAtlas atlas,
  String text = '',
  Color color = const Color(0xFFFFFFFF),
  double letterSpacing = 0.0,
  super.position,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility implements OpacityProvider {
  this {
    _recomputeSize();
  }

  static final GlyphBatchRenderer _standaloneScratch = GlyphBatchRenderer(
    initialGlyphCapacity: 64,
  );

  RasterFontAtlas _atlas = atlas;
  String _text = text;
  Color _color = color;

  /// Font atlas the glyphs of [text] are taken from. Assigning another atlas
  /// re-measures the component.
  RasterFontAtlas get atlas => _atlas;
  set atlas(RasterFontAtlas value) {
    if (!identical(_atlas, value)) {
      _atlas = value;
      _recomputeSize();
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  double _letterSpacing = letterSpacing;
  double _opacity = 1.0;

  /// Tint color applied to baked glyphs.
  Color get color => _color;
  set color(Color value) {
    if (_color != value) {
      _color = value;
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  /// String rendered by this component.
  String get text => _text;
  set text(String value) {
    if (_text != value) {
      _text = value;
      _recomputeSize();
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  /// Extra horizontal spacing in logical pixels between consecutive glyphs.
  double get letterSpacing => _letterSpacing;
  set letterSpacing(double value) {
    if (_letterSpacing != value) {
      _letterSpacing = value;
      _recomputeSize();
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  @override
  double get opacity => _opacity;

  @override
  set opacity(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if ((_opacity - clamped).abs() > 1e-6) {
      _opacity = clamped;
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  /// Effective modulated color incorporating [opacity].
  Color get effectiveColor => _opacity >= 0.9999
      ? color
      : color.withValues(alpha: (color.a * _opacity).clamp(0.0, 1.0));

  void _recomputeSize() {
    size.setValues(
      atlas.measureWidth(_text, letterSpacing: _letterSpacing),
      atlas.lineHeight * atlas.lineCountOf(_text),
    );
  }

  @override
  void render(Canvas canvas) {
    if (_text.isEmpty || _opacity <= 0.0 || atlas.isDisposed) {
      return;
    }
    _standaloneScratch
      ..begin()
      ..addText(
        atlas,
        _text,
        x: 0,
        y: 0,
        color: effectiveColor,
        letterSpacing: _letterSpacing,
      )
      ..flush(canvas, atlas);
  }
}

/// Container component that merges compatible child [BatchedTextComponent]s
/// sharing a [RasterFontAtlas] into a single `Canvas.drawRawAtlas` call per
/// frame.
class GlyphBatchLayer({
  var bool batchingEnabled = true,
  int initialGlyphCapacity = 256,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends Component {
  final GlyphBatchRenderer _renderer = GlyphBatchRenderer(
    initialGlyphCapacity: initialGlyphCapacity,
  );

  int _lastBatchedComponentCount = 0;
  int _lastBatchedGlyphCount = 0;
  int _lastAtlasDrawCalls = 0;

  /// Number of child [BatchedTextComponent]s merged on the last render pass.
  int get lastBatchedComponentCount => _lastBatchedComponentCount;

  /// Total glyphs submitted through batched `drawRawAtlas` calls on the last
  /// render pass.
  int get lastBatchedGlyphCount => _lastBatchedGlyphCount;

  /// Number of `Canvas.drawRawAtlas` calls issued on the last render pass.
  int get lastAtlasDrawCalls => _lastAtlasDrawCalls;

  @override
  void renderTree(Canvas canvas) {
    // This override replaces [Component.renderTree], so it has to apply the
    // same graphics tier and camera mask gates, to itself and to the children
    // it draws without going through their own `renderTree`.
    if (!isActiveForCurrentGraphicsTier) {
      return;
    }
    final activeCamera = CameraComponent.currentCamera;
    final activeMask = activeCamera?.cameraMask;
    if (activeMask != null && (cameraMask & activeMask) == 0) {
      return;
    }
    render(canvas);
    if (!hasChildren) {
      _lastBatchedComponentCount = 0;
      _lastBatchedGlyphCount = 0;
      _lastAtlasDrawCalls = 0;
      return;
    }
    if (!batchingEnabled) {
      _lastBatchedComponentCount = 0;
      _lastBatchedGlyphCount = 0;
      _lastAtlasDrawCalls = 0;
      for (final child in children) {
        child.renderTree(canvas);
      }
      return;
    }

    RasterFontAtlas? activeAtlas;
    var batchedComponents = 0;
    var totalGlyphs = 0;
    var drawCalls = 0;
    _renderer.begin();

    void flushActive() {
      if (activeAtlas != null && _renderer.bufferedGlyphCount > 0) {
        _renderer.flush(canvas, activeAtlas!);
        totalGlyphs += _renderer.lastFlushedGlyphs;
        drawCalls += _renderer.lastFlushDrawCalls;
      } else {
        _renderer.begin();
      }
      activeAtlas = null;
    }

    for (final child in children) {
      if (child is HasVisibility && !child.isVisible) {
        continue;
      }
      if (!child.isActiveForCurrentGraphicsTier ||
          (activeMask != null && (child.cameraMask & activeMask) == 0)) {
        continue;
      }
      if (child is BatchedTextComponent &&
          !child.hasChildren &&
          (child.scale.x - child.scale.y).abs() < 1e-5 &&
          child.scale.x > 0 &&
          child.decorator.isLastDecorator) {
        final atlas = child.atlas;
        if (atlas.isDisposed || child.text.isEmpty || child.opacity <= 0.0) {
          batchedComponents++;
          continue;
        }
        var extraScale = 1.0;
        var extraRot = 0.0;
        final cam = CameraComponent.currentCamera;
        if (child is CameraBillboard && cam != null) {
          final bb = child as CameraBillboard;
          if (bb.billboardEnabled) {
            extraScale = bb.computeBillboardScale(cam.viewfinder.zoom);
            if (bb.compensateCameraRotation) {
              extraRot = -cam.viewfinder.angle;
            }
          }
        }
        if (activeAtlas != null && !identical(activeAtlas, atlas)) {
          flushActive();
        }
        activeAtlas = atlas;
        _renderer.addText(
          atlas,
          child.text,
          x: child.position.x,
          y: child.position.y,
          anchor: child.anchor,
          scale: child.scale.x * extraScale,
          rotation: child.angle + extraRot,
          color: child.effectiveColor,
          letterSpacing: child.letterSpacing,
        );
        batchedComponents++;
        continue;
      }

      flushActive();
      child.renderTree(canvas);
    }

    flushActive();
    _lastBatchedComponentCount = batchedComponents;
    _lastBatchedGlyphCount = totalGlyphs;
    _lastAtlasDrawCalls = drawCalls;
  }
}
