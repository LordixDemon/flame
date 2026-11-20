import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/input.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/ui3d/picture_texture.dart';
import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter/painting.dart'
    show TextDirection, TextPainter, TextSpan, TextStyle;

/// Base interactive 2D control hosted on a [WidgetSurface3D] panel.
abstract class SurfaceControl2D({
  required var ui.Rect bounds,
  var bool enabled = true,
}) {
  WidgetSurface3D? _owner;

  /// Whether a 3D pointer ray is currently hovering inside [bounds].
  bool hovered = false;

  /// Whether this control is currently held down by an active tap/drag.
  bool pressed = false;

  /// Marks the owning [WidgetSurface3D] dirty so its texture re-renders.
  void invalidate() {
    _owner?.markDirty();
  }

  /// Paints this control onto [canvas] in panel pixel coordinates.
  void paint(ui.Canvas canvas);

  /// Handles pointer press at [panelOffset].
  void handlePointerDown(ui.Offset panelOffset) {}

  /// Handles pointer drag at [panelOffset].
  void handlePointerDrag(ui.Offset panelOffset) {}

  /// Handles pointer release (`inside` indicates whether release landed inside
  /// [bounds]).
  void handlePointerUp(ui.Offset panelOffset, {required bool inside}) {}
}

/// Interactive 2D button control for a diegetic [WidgetSurface3D].
class SurfaceButton2D({
  required super.bounds,
  var String label = '',
  this.onPressed,
  var ui.Color normalColor = const ui.Color(0xFF1E293B),
  var ui.Color hoverColor = const ui.Color(0xFF334155),
  var ui.Color pressedColor = const ui.Color(0xFF0EA5E9),
  var ui.Color borderColor = const ui.Color(0xFF38BDF8),
  var ui.Color textColor = const ui.Color(0xFFF8FAFC),
  var double borderRadius = 8.0,
  var double fontSize = 18.0,
  super.enabled,
}) extends SurfaceControl2D {
  /// Callback invoked when a tap completes inside [bounds].
  ui.VoidCallback? onPressed;

  @override
  void handlePointerUp(ui.Offset panelOffset, {required bool inside}) {
    if (enabled && inside) {
      onPressed?.call();
    }
  }

  @override
  void paint(ui.Canvas canvas) {
    final fill = !enabled
        ? const ui.Color(0xFF0F172A)
        : pressed
        ? pressedColor
        : hovered
        ? hoverColor
        : normalColor;
    final rrect = ui.RRect.fromRectAndRadius(
      bounds,
      ui.Radius.circular(borderRadius),
    );
    canvas
      ..drawRRect(rrect, ui.Paint()..color = fill)
      ..drawRRect(
        rrect,
        ui.Paint()
          ..color = borderColor
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = hovered || pressed ? 2.5 : 1.5,
      );

    if (label.isNotEmpty) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontWeight: ui.FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(0.0, bounds.width - 8.0));
      final tx = bounds.left + (bounds.width - painter.width) * 0.5;
      final ty = bounds.top + (bounds.height - painter.height) * 0.5;
      painter
        ..paint(canvas, ui.Offset(tx, ty))
        ..dispose();
    }
  }
}

/// Interactive horizontal 2D slider control for a diegetic [WidgetSurface3D].
class SurfaceSlider2D({
  required super.bounds,
  double value = 0.5,
  final double min = 0.0,
  final double max = 1.0,
  this.onChanged,
  var ui.Color trackColor = const ui.Color(0xFF1E293B),
  var ui.Color activeColor = const ui.Color(0xFF38BDF8),
  var ui.Color thumbColor = const ui.Color(0xFFF8FAFC),
  super.enabled,
}) extends SurfaceControl2D {
  this : assert(max > min, 'max must be > min') {
    _value = value.clamp(min, max);
  }

  double _value = 0.5;

  /// Callback invoked whenever [value] changes via click or drag.
  ValueChanged<double>? onChanged;

  /// Current slider value in `[min..max]`.
  double get value => _value;
  set value(double next) {
    final clamped = next.clamp(min, max);
    if ((clamped - _value).abs() > 1e-6) {
      _value = clamped;
      invalidate();
    }
  }

  /// Normalized `[0..1]` slider fraction.
  double get normalizedValue => ((_value - min) / (max - min)).clamp(0.0, 1.0);

  void _scrubAt(double panelX) {
    if (!enabled || bounds.width <= 1e-6) {
      return;
    }
    final t = ((panelX - bounds.left) / bounds.width).clamp(0.0, 1.0);
    final next = min + (max - min) * t;
    if ((next - _value).abs() > 1e-6) {
      _value = next;
      invalidate();
      onChanged?.call(_value);
    }
  }

  @override
  void handlePointerDown(ui.Offset panelOffset) {
    _scrubAt(panelOffset.dx);
  }

  @override
  void handlePointerDrag(ui.Offset panelOffset) {
    _scrubAt(panelOffset.dx);
  }

  @override
  void paint(ui.Canvas canvas) {
    final cy = bounds.center.dy;
    final trackHeight = math.min(8.0, bounds.height * 0.35);
    final trackRect = ui.Rect.fromLTWH(
      bounds.left,
      cy - trackHeight * 0.5,
      bounds.width,
      trackHeight,
    );
    final trackRRect = ui.RRect.fromRectAndRadius(
      trackRect,
      ui.Radius.circular(trackHeight * 0.5),
    );
    canvas.drawRRect(trackRRect, ui.Paint()..color = trackColor);

    final frac = normalizedValue;
    final fillW = bounds.width * frac;
    if (fillW > 0.5) {
      final fillRect = ui.Rect.fromLTWH(
        bounds.left,
        cy - trackHeight * 0.5,
        fillW,
        trackHeight,
      );
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          fillRect,
          ui.Radius.circular(trackHeight * 0.5),
        ),
        ui.Paint()..color = activeColor,
      );
    }

    final thumbRadius = math.min(
      bounds.height * 0.45,
      pressed || hovered ? 10.0 : 8.5,
    );
    final thumbX = bounds.left + fillW;
    canvas.drawCircle(
      ui.Offset(thumbX, cy),
      thumbRadius,
      ui.Paint()..color = thumbColor,
    );
  }
}

/// Interactive diegetic 2D-in-3D world panel mapping a custom `dart:ui`
/// [paintSurface] canvas plus [SurfaceControl2D]s ([SurfaceButton2D],
/// [SurfaceSlider2D] or your own) onto an [ImageTexture] quad in 3D space.
///
/// Despite its name it does not host Flutter widgets: there is no widget
/// tree, layout, text field, scrolling or focus. What it shows is painted
/// with `dart:ui` by [paintSurface] and by its controls.
///
/// Integrates with [PointerRouter3D] via [TapCallbacks3D],
/// [HoverCallbacks3D], and [DragCallbacks3D], projecting 3D ray hits onto
/// panel pixel coordinates `Offset(u * pixelWidth, v * pixelHeight)`. The
/// canvas is rasterized again only when dirty; the previous texture is
/// disposed, and so is the last one when the panel is removed.
///
/// It needs a GPU backend that can use a `dart:ui` image as a texture
/// (Flutter GPU on Android, iOS and macOS): on another one, such as WebGPU on
/// the web, creating a panel throws an [UnsupportedError].
class WidgetSurface3D({
  final double width = 2.0,
  final double height = 1.2,
  final int pixelWidth = 512,
  final int pixelHeight = 300,
  this.paintSurface,
  List<SurfaceControl2D> controls = const [],
  this.onSurfaceTap,
  this.onSurfaceHover,
  this.onSurfaceDrag,
  var ui.Color backgroundColor = const ui.Color(0xE60F172A),
  var double minUploadInterval = 0.0,
  final bool doubleSided = true,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.cameraMask,
}) extends Object3D with TapCallbacks3D, HoverCallbacks3D, DragCallbacks3D {
  this
    : assert(width > 0, 'width must be positive'),
      assert(height > 0, 'height must be positive'),
      assert(pixelWidth > 0, 'pixelWidth must be positive'),
      assert(pixelHeight > 0, 'pixelHeight must be positive'),
      super(castsShadows: false) {
    for (final c in controls) {
      addControl(c);
    }
    _material = UnlitMaterial()
      ..renderState = RenderState(
        blend: BlendState.premultipliedAlpha,
        cullMode: doubleSided ? CullMode.none : CullMode.backFace,
      );
    _panelMesh = _buildPanelMesh(width, height, _material);
    _refreshTextureNow();
  }

  /// Optional custom 2D canvas painter invoked before [controls] whenever this
  /// surface is dirty.
  void Function(ui.Canvas canvas, ui.Size size)? paintSurface;

  /// Optional callback invoked with panel pixel coordinates on tap-up.
  void Function(ui.Offset panelOffset)? onSurfaceTap;

  /// Optional callback invoked with panel pixel coordinates on hover enter/move.
  void Function(ui.Offset panelOffset)? onSurfaceHover;

  /// Optional callback invoked with `(panelOffset, deltaOffset)` during drags.
  void Function(ui.Offset panelOffset, ui.Offset deltaOffset)? onSurfaceDrag;

  final List<SurfaceControl2D> _controls = [];
  late final UnlitMaterial _material;
  late final Mesh _panelMesh;

  ImageTexture? _surfaceTexture;
  ByteData? _fallbackRgba;
  bool _dirty = false;
  int _uploadCount = 0;
  double _sinceLastUpload = double.infinity;

  SurfaceControl2D? _pressedControl;
  SurfaceControl2D? _draggedControl;
  ui.Offset? _lastDragPanelOffset;

  final Matrix4 _invWorld = Matrix4.identity();
  final Vector3 _worldNormal = Vector3(0.0, 0.0, 1.0);

  /// Registered interactive controls in paint order (hit-tested top-to-bottom).
  List<SurfaceControl2D> get controls =>
      List<SurfaceControl2D>.unmodifiable(_controls);

  /// Current [ImageTexture] mapped onto this 3D panel.
  ImageTexture get surfaceTexture => _surfaceTexture!;

  /// Backing [UnlitMaterial] rendering [surfaceTexture].
  UnlitMaterial get material => _material;

  /// Whether this panel has pending visual changes awaiting GPU upload.
  bool get isDirty => _dirty;

  /// Total number of times this panel's 2D canvas has been rasterized and
  /// uploaded to [ImageTexture] (`1` initially; remains unchanged while clean).
  int get uploadCount => _uploadCount;

  /// Adds [control] to this surface and marks the panel dirty.
  void addControl(SurfaceControl2D control) {
    if (!_controls.contains(control)) {
      control._owner = this;
      _controls.add(control);
      markDirty();
    }
  }

  /// Removes [control] from this surface and marks the panel dirty.
  void removeControl(SurfaceControl2D control) {
    if (_controls.remove(control)) {
      control._owner = null;
      markDirty();
    }
  }

  /// Marks this 3D UI panel dirty so its 2D canvas re-rasterizes on the next
  /// frame (subject to [minUploadInterval]).
  void markDirty() {
    _dirty = true;
    worldOrNull?.markSceneDirty(shadows: false);
  }

  /// Flushes any pending [isDirty] repaint immediately regardless of
  /// [minUploadInterval].
  void flushDirty() {
    if (_dirty) {
      _refreshTextureNow();
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (dt > 0.0) {
      _sinceLastUpload += dt;
    }
    // Keep `dragPlaneNormal` aligned with the panel's world-space +Z normal.
    final m = worldTransformMatrix.storage;
    _worldNormal.setValues(m[8], m[9], m[10]);
    if (_worldNormal.length2 > 1e-12) {
      _worldNormal.normalize();
      dragPlaneNormal = _worldNormal;
    }
    if (_dirty && _sinceLastUpload >= minUploadInterval) {
      _refreshTextureNow();
    }
  }

  @override
  Aabb3? computeLocalAabb() => _panelMesh.aabb;

  // Whether the texture was disposed when the panel was removed.
  bool _textureReleased = false;

  @override
  void onMount() {
    super.onMount();
    GpuBackend.addDeviceListener(_deviceListener);
    if (_textureReleased) {
      _textureReleased = false;
      _refreshTextureNow();
    }
  }

  @override
  void onRemove() {
    GpuBackend.removeDeviceListener(_deviceListener);
    final texture = _surfaceTexture;
    if (texture != null && texture.hasResource) {
      texture.dispose();
    }
    _textureReleased = true;
    super.onRemove();
  }

  @override
  void draw(covariant RenderContext3D context) {
    if (context.isShadowPass) {
      return;
    }
    if (_dirty && _sinceLastUpload >= minUploadInterval) {
      _refreshTextureNow();
    }
    context.drawMesh(_panelMesh, transform: worldTransformMatrix);
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    final m = worldTransformMatrix.storage;
    _worldNormal.setValues(m[8], m[9], m[10]);
    if (_worldNormal.length2 > 1e-12) {
      _worldNormal.normalize();
      dragPlaneNormal = _worldNormal;
    }
    return RayHit3D.intersectMesh(
      owner: this,
      mesh: _panelMesh,
      modelMatrix: worldTransformMatrix,
      worldRay: worldRay,
      maxDistance: maxDistance,
      cullMode: cullMode ?? (doubleSided ? CullMode.none : CullMode.backFace),
    );
  }

  /// Projects a 3D [RayHit3D] or [worldRay] onto normalized `(u, v)` (`[0..1]`)
  /// and pixel `Offset(u * pixelWidth, v * pixelHeight)` on this panel.
  ui.Offset resolvePanelOffset({
    RayHit3D? hit,
    Ray? worldRay,
    Vector3? worldPoint,
  }) {
    double lx;
    double ly;
    if (hit != null && identical(hit.object, this)) {
      lx = hit.localPoint.x;
      ly = hit.localPoint.y;
    } else {
      _invWorld.setFrom(worldTransformMatrix);
      final det = _invWorld.invert();
      if (det.abs() < 1e-15) {
        return ui.Offset.zero;
      }
      if (worldRay != null) {
        final s = _invWorld.storage;
        final ox = worldRay.origin.x;
        final oy = worldRay.origin.y;
        final oz = worldRay.origin.z;
        final dx = worldRay.direction.x;
        final dy = worldRay.direction.y;
        final dz = worldRay.direction.z;
        final lox = s[0] * ox + s[4] * oy + s[8] * oz + s[12];
        final loy = s[1] * ox + s[5] * oy + s[9] * oz + s[13];
        final loz = s[2] * ox + s[6] * oy + s[10] * oz + s[14];
        final ldx = s[0] * dx + s[4] * dy + s[8] * dz;
        final ldy = s[1] * dx + s[5] * dy + s[9] * dz;
        final ldz = s[2] * dx + s[6] * dy + s[10] * dz;
        if (ldz.abs() > 1e-9) {
          final t = -loz / ldz;
          lx = lox + ldx * t;
          ly = loy + ldy * t;
        } else if (worldPoint != null) {
          final lp = _invWorld.transformed3(worldPoint.clone());
          lx = lp.x;
          ly = lp.y;
        } else {
          lx = lox;
          ly = loy;
        }
      } else if (worldPoint != null) {
        final lp = _invWorld.transformed3(worldPoint.clone());
        lx = lp.x;
        ly = lp.y;
      } else {
        return ui.Offset.zero;
      }
    }

    final u = ((lx / width) + 0.5).clamp(0.0, 1.0);
    final v = (0.5 - (ly / height)).clamp(0.0, 1.0);
    return ui.Offset(u * pixelWidth, v * pixelHeight);
  }

  SurfaceControl2D? _hitControl(ui.Offset panelOffset) {
    for (var i = _controls.length - 1; i >= 0; i--) {
      final c = _controls[i];
      if (c.enabled && c.bounds.contains(panelOffset)) {
        return c;
      }
    }
    return null;
  }

  void _updateHoverAt(ui.Offset panelOffset) {
    final hoveredTarget = _hitControl(panelOffset);
    var stateChanged = false;
    for (var i = 0; i < _controls.length; i++) {
      final c = _controls[i];
      final nextHover = identical(c, hoveredTarget);
      if (c.hovered != nextHover) {
        c.hovered = nextHover;
        stateChanged = true;
      }
    }
    if (stateChanged) {
      markDirty();
    }
    onSurfaceHover?.call(panelOffset);
  }

  // ---------------------------------------------------------------------------
  // PointerRouter3D Callbacks
  // ---------------------------------------------------------------------------

  @override
  void onTapDown3D(TapDownEvent3D event) {
    final pos = resolvePanelOffset(hit: event.hit, worldRay: event.worldRay);
    final hitCtrl = _hitControl(pos);
    _pressedControl = hitCtrl;
    if (hitCtrl != null) {
      if (!hitCtrl.pressed) {
        hitCtrl.pressed = true;
        markDirty();
      }
      hitCtrl.handlePointerDown(pos);
    }
    event.handled = true;
  }

  @override
  void onTapUp3D(TapUpEvent3D event) {
    final pos = resolvePanelOffset(hit: event.hit, worldRay: event.worldRay);
    final active = _pressedControl;
    _pressedControl = null;
    if (active != null) {
      if (active.pressed) {
        active.pressed = false;
        markDirty();
      }
      active.handlePointerUp(pos, inside: active.bounds.contains(pos));
    }
    onSurfaceTap?.call(pos);
    event.handled = true;
  }

  @override
  void onTapCancel3D(TapCancelEvent3D event) {
    final active = _pressedControl;
    _pressedControl = null;
    if (active != null && active.pressed) {
      active.pressed = false;
      markDirty();
    }
    event.handled = true;
  }

  @override
  void onHoverEnter3D(HoverEnterEvent3D event) {
    final pos = resolvePanelOffset(hit: event.hit, worldRay: event.worldRay);
    _updateHoverAt(pos);
    event.handled = true;
  }

  @override
  void onHoverMove3D(HoverMoveEvent3D event) {
    final pos = resolvePanelOffset(hit: event.hit, worldRay: event.worldRay);
    _updateHoverAt(pos);
    event.handled = true;
  }

  @override
  void onHoverExit3D(HoverExitEvent3D event) {
    var changed = false;
    for (var i = 0; i < _controls.length; i++) {
      if (_controls[i].hovered) {
        _controls[i].hovered = false;
        changed = true;
      }
    }
    if (changed) {
      markDirty();
    }
  }

  @override
  void onDragStart3D(DragStartEvent3D event) {
    final pos = resolvePanelOffset(
      hit: event.hit,
      worldRay: event.worldRay,
      worldPoint: event.worldPlanePoint,
    );
    _lastDragPanelOffset = pos;
    final ctrl = _hitControl(pos);
    _draggedControl = ctrl;
    if (ctrl != null) {
      if (!ctrl.pressed) {
        ctrl.pressed = true;
        markDirty();
      }
      ctrl.handlePointerDown(pos);
    }
    event.handled = true;
  }

  @override
  void onDragUpdate3D(DragUpdateEvent3D event) {
    final pos = resolvePanelOffset(
      hit: event.hit,
      worldRay: event.worldRay,
      worldPoint: event.worldPlanePoint,
    );
    final prev = _lastDragPanelOffset ?? pos;
    final delta = pos - prev;
    _lastDragPanelOffset = pos;
    _draggedControl?.handlePointerDrag(pos);
    onSurfaceDrag?.call(pos, delta);
    event.handled = true;
  }

  @override
  void onDragEnd3D(DragEndEvent3D event) {
    final pos = resolvePanelOffset(
      hit: event.hit,
      worldRay: event.worldRay,
      worldPoint: event.worldPlanePoint,
    );
    final ctrl = _draggedControl;
    _draggedControl = null;
    _lastDragPanelOffset = null;
    if (ctrl != null) {
      if (ctrl.pressed) {
        ctrl.pressed = false;
        markDirty();
      }
      if (!event.wasCancelled) {
        ctrl.handlePointerUp(pos, inside: ctrl.bounds.contains(pos));
      }
    }
    event.handled = true;
  }

  // ---------------------------------------------------------------------------
  // Texture Rasterization
  // ---------------------------------------------------------------------------

  void _refreshTextureNow() {
    _dirty = false;
    _sinceLastUpload = 0.0;
    _uploadCount++;

    final size = ui.Size(pixelWidth.toDouble(), pixelHeight.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    if (backgroundColor.a > 0) {
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, size.width, size.height),
        ui.Paint()..color = backgroundColor,
      );
    }
    paintSurface?.call(canvas, size);
    for (var i = 0; i < _controls.length; i++) {
      _controls[i].paint(canvas);
    }

    final picture = recorder.endRecording();
    final request = ++_rasterRequest;
    final ready = rasterizePictureTexture(
      picture,
      pixelWidth,
      pixelHeight,
      'WidgetSurface3D',
      (gpuTex) {
        // A later refresh, or the panel's removal, replaced this request.
        if (request == _rasterRequest && !_textureReleased) {
          _useTexture(gpuTex);
        }
      },
    );
    if (!ready && _surfaceTexture == null) {
      // Nothing to show until the picture is rasterized (on devices).
      _material.albedoTexture = Texture.empty;
    }
  }

  // The number of texture refreshes requested, so that a rasterization that
  // completes after a newer request is dropped.
  int _rasterRequest = 0;

  // Rasterizes the panel again after a GPU device loss: its texture wrapped
  // an image of the lost device.
  late final GpuDeviceListener _deviceListener = GpuDeviceListener(
    onRecovered: (_) => markDirty(),
  );

  void _useTexture(GpuTexture? gpuTex) {
    final prevTex = _surfaceTexture;
    if (gpuTex != null) {
      _surfaceTexture = ImageTexture(
        null,
        width: pixelWidth,
        height: pixelHeight,
        sampler: TextureSampler.linear,
        gpuTexture: gpuTex,
      );
    } else {
      // Without a GPU (a plain `flutter test`) nothing is drawn.
      final fallback = _fallbackRgba ??= ByteData(pixelWidth * pixelHeight * 4);
      _surfaceTexture = ImageTexture(
        fallback,
        width: pixelWidth,
        height: pixelHeight,
        sampler: TextureSampler.linear,
      );
    }
    _material.albedoTexture = _surfaceTexture!;
    if (prevTex != null && prevTex.hasResource) {
      prevTex.dispose();
    }
    worldOrNull?.markSceneDirty(shadows: false);
  }

  static Mesh _buildPanelMesh(
    double width,
    double height,
    Material material,
  ) {
    final hw = width * 0.5;
    final hh = height * 0.5;
    final surface = Surface(
      vertices: [
        Vertex(
          position: Vector3(-hw, -hh, 0.0),
          texCoord: Vector2(0.0, 1.0),
          normal: Vector3(0.0, 0.0, 1.0),
        ),
        Vertex(
          position: Vector3(hw, -hh, 0.0),
          texCoord: Vector2(1.0, 1.0),
          normal: Vector3(0.0, 0.0, 1.0),
        ),
        Vertex(
          position: Vector3(hw, hh, 0.0),
          texCoord: Vector2(1.0, 0.0),
          normal: Vector3(0.0, 0.0, 1.0),
        ),
        Vertex(
          position: Vector3(-hw, hh, 0.0),
          texCoord: Vector2(0.0, 0.0),
          normal: Vector3(0.0, 0.0, 1.0),
        ),
      ],
      indices: const [0, 1, 2, 0, 2, 3],
      material: material,
    );
    return Mesh()..addSurface(surface);
  }
}
