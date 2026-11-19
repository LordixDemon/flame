import 'dart:collection' show UnmodifiableListView;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/embedding/embedded_renderer.dart';

/// Framebuffer clear behavior for a [CameraViewportSlot3D] in a
/// [CameraStack3D].
enum CameraClearMode3D() {
  /// Clears both color and depth for the slot's viewport region before drawing.
  colorAndDepth,

  /// Clears depth (`1.0`) while preserving underlying color on the canvas.
  ///
  /// Ideal for rendering 3D first-person hands/weapons, 3D HUD widgets, or 3D
  /// transform gizmos on top of the main world without clipping through walls.
  depthOnly,

  /// Preserves underlying color on the canvas, compositing the slot's pass
  /// directly on top of previous slots.
  none,
}

/// Result of mapping a 2D screen coordinate through [CameraStack3D].
class CameraSlotPickResult3D({
  required final CameraViewportSlot3D slot,
  required final Rect pixelRect,
  required final Vector2 localViewportPoint,
  required final Ray worldRay,
}) {
  /// Camera belonging to the matched [slot].
  CameraComponent3D get camera => slot.camera;
}

/// One camera viewport layer inside a [CameraStack3D].
///
/// [normalizedViewport] uses normalized `[0..1]` screen coordinates where
/// `(0, 0)` is top-left and `(1, 1)` is bottom-right:
/// - `Rect.fromLTWH(0, 0, 1, 1)` — full-screen pass (default),
/// - `Rect.fromLTWH(0, 0, 0.5, 1)` / `Rect.fromLTWH(0.5, 0, 0.5, 1)` —
///   2-player horizontal split-screen,
/// - `Rect.fromLTWH(0.72, 0.04, 0.25, 0.25)` — picture-in-picture minimap or
///   rear-view mirror.
class CameraViewportSlot3D({
  required final CameraComponent3D camera,
  var World3D? world,
  var Rect normalizedViewport = const Rect.fromLTWH(0, 0, 1, 1),
  var int priority = 0,
  var CameraClearMode3D clearMode = CameraClearMode3D.colorAndDepth,
  var Color? clearColor,
  var bool enabled = true,
  var Color? borderColor,
  var double borderWidth = 1.5,
  var String? label,
}) {
  /// Resolves [normalizedViewport] against [canvasSize] into logical pixels.
  Rect resolvePixelRect(Size canvasSize) {
    final left = normalizedViewport.left * canvasSize.width;
    final top = normalizedViewport.top * canvasSize.height;
    final width = math.max(0.0, normalizedViewport.width * canvasSize.width);
    final height = math.max(0.0, normalizedViewport.height * canvasSize.height);
    return Rect.fromLTWH(left, top, width, height);
  }

  /// Synchronizes [camera]'s viewport size to the pixel dimensions of this slot
  /// for [canvasSize] so aspect ratio and ray unprojection match the slot.
  Rect syncCameraViewport(Size canvasSize) {
    final rect = resolvePixelRect(canvasSize);
    if (rect.width > 0 && rect.height > 0) {
      final vpSize = camera.viewport.virtualSize;
      if (vpSize.x != rect.width || vpSize.y != rect.height) {
        final nextSize = Vector2(rect.width, rect.height);
        camera.viewport.onGameResize(nextSize);
        if (camera.isMounted) {
          camera.onGameResize(nextSize);
        }
      }
    }
    return rect;
  }
}

/// Multi-camera compositor supporting split-screen viewports, picture-in-
/// picture minimaps, and `depthOnly` 3D weapon/HUD/gizmo overlay passes.
class CameraStack3D({
  List<CameraViewportSlot3D> slots = const [],
}) {
  /// Builds a 2-player left/right horizontal split-screen stack.
  factory CameraStack3D.splitHorizontal(
    CameraComponent3D left,
    CameraComponent3D right, {
    Color? borderColor,
    double borderWidth = 1.5,
  }) {
    return CameraStack3D(
      slots: [
        CameraViewportSlot3D(
          camera: left,
          normalizedViewport: const Rect.fromLTWH(0, 0, 0.5, 1),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'left',
        ),
        CameraViewportSlot3D(
          camera: right,
          normalizedViewport: const Rect.fromLTWH(0.5, 0, 0.5, 1),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'right',
        ),
      ],
    );
  }

  /// Builds a 2-player top/bottom vertical split-screen stack.
  factory CameraStack3D.splitVertical(
    CameraComponent3D top,
    CameraComponent3D bottom, {
    Color? borderColor,
    double borderWidth = 1.5,
  }) {
    return CameraStack3D(
      slots: [
        CameraViewportSlot3D(
          camera: top,
          normalizedViewport: const Rect.fromLTWH(0, 0, 1, 0.5),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'top',
        ),
        CameraViewportSlot3D(
          camera: bottom,
          normalizedViewport: const Rect.fromLTWH(0, 0.5, 1, 0.5),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'bottom',
        ),
      ],
    );
  }

  /// Builds a 4-way quadrant split-screen stack.
  factory CameraStack3D.quad(
    CameraComponent3D topLeft,
    CameraComponent3D topRight,
    CameraComponent3D bottomLeft,
    CameraComponent3D bottomRight, {
    Color? borderColor,
    double borderWidth = 1.5,
  }) {
    return CameraStack3D(
      slots: [
        CameraViewportSlot3D(
          camera: topLeft,
          normalizedViewport: const Rect.fromLTWH(0, 0, 0.5, 0.5),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'topLeft',
        ),
        CameraViewportSlot3D(
          camera: topRight,
          normalizedViewport: const Rect.fromLTWH(0.5, 0, 0.5, 0.5),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'topRight',
        ),
        CameraViewportSlot3D(
          camera: bottomLeft,
          normalizedViewport: const Rect.fromLTWH(0, 0.5, 0.5, 0.5),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'bottomLeft',
        ),
        CameraViewportSlot3D(
          camera: bottomRight,
          normalizedViewport: const Rect.fromLTWH(0.5, 0.5, 0.5, 0.5),
          borderColor: borderColor,
          borderWidth: borderWidth,
          label: 'bottomRight',
        ),
      ],
    );
  }

  this {
    for (final slot in slots) {
      addSlot(slot);
    }
  }

  final List<_IndexedSlot> _entries = [];
  List<CameraViewportSlot3D>? _sortedCache;
  int _nextOrder = 0;
  int _lastRenderedSlotCount = 0;

  final Paint _compositePaint = Paint();
  final Paint _borderPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _clearPaint = Paint();

  /// Number of slots in this stack.
  int get length => _entries.length;

  /// Whether this stack has no slots.
  bool get isEmpty => _entries.isEmpty;

  /// Whether this stack has at least one slot.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// Number of enabled slots rendered in the most recent [render] call.
  int get lastRenderedSlotCount => _lastRenderedSlotCount;

  /// Slots ordered from lowest [CameraViewportSlot3D.priority] to highest
  /// (stable insertion order for ties).
  List<CameraViewportSlot3D> get slots {
    return UnmodifiableListView(_ensureSorted());
  }

  List<CameraViewportSlot3D> _ensureSorted() {
    // Re-sort whenever priorities may have changed dynamically.
    final sorted = List<_IndexedSlot>.of(_entries)
      ..sort((a, b) {
        final cmp = a.slot.priority.compareTo(b.slot.priority);
        return cmp != 0 ? cmp : a.order.compareTo(b.order);
      });
    final list = [for (final item in sorted) item.slot];
    _sortedCache = list;
    return _sortedCache!;
  }

  /// Appends [slot] to this stack.
  void addSlot(CameraViewportSlot3D slot) {
    _entries.add(_IndexedSlot(slot, _nextOrder++));
    _sortedCache = null;
  }

  /// Removes [slot] from this stack, returning `true` if it was present.
  bool removeSlot(CameraViewportSlot3D slot) {
    final idx = _entries.indexWhere((e) => identical(e.slot, slot));
    if (idx < 0) {
      return false;
    }
    _entries.removeAt(idx);
    _sortedCache = null;
    return true;
  }

  /// Removes all slots from this stack.
  void clear() {
    _entries.clear();
    _sortedCache = null;
  }

  /// Advances unmounted cameras in this stack by [dt].
  void update(double dt) {
    for (final entry in _entries) {
      final slot = entry.slot;
      if (slot.enabled && !slot.camera.isMounted) {
        slot.camera.update(dt);
      }
    }
  }

  /// Maps [screenPoint] (within `[0..canvasSize.width, 0..canvasSize.height]`)
  /// to the topmost enabled [CameraViewportSlot3D], its local viewport point,
  /// and its unprojected world-space [Ray].
  ///
  /// Returns `null` when [screenPoint] lies outside every enabled slot or when
  /// [canvasSize] is empty.
  CameraSlotPickResult3D? pickSlotAndRay(
    Vector2 screenPoint,
    Size canvasSize,
  ) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) {
      return null;
    }
    final ordered = _ensureSorted();
    for (var i = ordered.length - 1; i >= 0; i--) {
      final slot = ordered[i];
      if (!slot.enabled) {
        continue;
      }
      final rect = slot.resolvePixelRect(canvasSize);
      if (rect.width <= 0 || rect.height <= 0) {
        continue;
      }
      if (!_rectContainsPoint(rect, screenPoint, canvasSize)) {
        continue;
      }
      slot.syncCameraViewport(canvasSize);
      final local = Vector2(
        screenPoint.x - rect.left,
        screenPoint.y - rect.top,
      );
      final ray = slot.camera.viewportPointToRay(local);
      return CameraSlotPickResult3D(
        slot: slot,
        pixelRect: rect,
        localViewportPoint: local,
        worldRay: ray,
      );
    }
    return null;
  }

  /// Picks the topmost active slot at [screenPoint] and raycasts into that
  /// slot's [World3D] honoring [CameraComponent3D.cameraMask] and
  /// [Component3D.isEffectivelyVisible].
  (CameraSlotPickResult3D, RayHit3D?)? raycastAt(
    Vector2 screenPoint,
    Size canvasSize, {
    World3D? defaultWorld,
    double maxDistance = double.infinity,
    CullMode? cullMode,
    bool Function(Object3D object)? filter,
  }) {
    final picked = pickSlotAndRay(screenPoint, canvasSize);
    if (picked == null) {
      return null;
    }
    final targetWorld =
        picked.slot.world ?? picked.camera.world ?? defaultWorld;
    if (targetWorld == null) {
      return (picked, null);
    }
    final mask = picked.camera.cameraMask;
    final hit = targetWorld.raycast(
      picked.worldRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
      filter: (obj) =>
          (obj.cameraMask & mask) != 0 &&
          obj.isEffectivelyVisible &&
          (filter == null || filter(obj)),
    );
    return (picked, hit);
  }

  /// Renders every enabled [CameraViewportSlot3D] in ascending priority order
  /// onto [canvas] within [canvasSize].
  ///
  /// Returns the number of slots rendered.
  int render(
    Canvas canvas,
    Size canvasSize, {
    World3D? defaultWorld,
    GraphicsDevice? device,
    RenderContext3D? context,
    bool manageDeviceFrame = false,
    double pixelRatio = 1.0,
    Msaa msaa = Msaa.off,
  }) {
    _lastRenderedSlotCount = 0;
    if (canvasSize.width <= 0 || canvasSize.height <= 0 || _entries.isEmpty) {
      return 0;
    }

    final ordered = _ensureSorted();
    final resolvedDevice = device;
    var resolvedContext = context;
    var openedDevice = false;
    EmbeddedRenderer? embedded;
    var openedEmbedded = false;

    if (resolvedDevice != null) {
      resolvedContext ??= RenderContext3D(resolvedDevice);
      if (manageDeviceFrame) {
        resolvedDevice.begin();
        openedDevice = true;
      }
    }

    try {
      var rendered = 0;
      for (final slot in ordered) {
        if (!slot.enabled) {
          continue;
        }
        final slotWorld = slot.world ?? slot.camera.world ?? defaultWorld;
        if (slotWorld == null) {
          continue;
        }
        final pixelRect = slot.syncCameraViewport(canvasSize);
        if (pixelRect.width <= 0 || pixelRect.height <= 0) {
          continue;
        }

        GraphicsDevice activeDevice;
        RenderContext3D activeContext;
        var closeGameDevice = false;
        if (resolvedDevice != null && resolvedContext != null) {
          activeDevice = resolvedDevice;
          activeContext = resolvedContext;
        } else if (slotWorld.findGame() case final Game3D game3d) {
          activeDevice = game3d.device;
          activeContext = game3d.context;
          if (!game3d.isRenderingFrame) {
            activeDevice.begin();
            closeGameDevice = true;
          }
        } else {
          embedded ??= EmbeddedRenderer.of(slotWorld.findGame() ?? this);
          if (!openedEmbedded) {
            openedEmbedded = embedded.open();
          }
          activeDevice = embedded.device;
          activeContext = embedded.context;
        }

        final scale = pixelRatio * slotWorld.renderScale;
        final passSize = Size(
          math.max(1.0, pixelRect.width * scale),
          math.max(1.0, pixelRect.height * scale),
        );

        final gpuClear = switch (slot.clearMode) {
          CameraClearMode3D.colorAndDepth =>
            slot.clearColor ?? activeDevice.clearValue,
          CameraClearMode3D.depthOnly ||
          CameraClearMode3D.none => const Color(0x00000000),
        };

        final prevMask = activeContext.cameraMask;
        activeContext.cameraMask = slot.camera.cameraMask;
        Image? image;
        try {
          image = slotWorld.renderToImage(
            passSize,
            view: slot.camera.viewMatrix,
            projection: slot.camera.projectionMatrix,
            msaa: msaa,
            clearValue: gpuClear,
            device: activeDevice,
            context: activeContext,
          );
        } finally {
          activeContext.cameraMask = prevMask;
          if (closeGameDevice) {
            activeDevice.end();
          }
        }

        canvas
          ..save()
          ..clipRect(pixelRect);
        if (slot.clearMode == CameraClearMode3D.colorAndDepth) {
          if (slot.clearColor case final bg?) {
            _clearPaint
              ..color = bg
              ..blendMode = BlendMode.src;
            canvas.drawRect(pixelRect, _clearPaint);
          } else if (rendered > 0) {
            _clearPaint
              ..color = const Color(0x00000000)
              ..blendMode = BlendMode.clear;
            canvas.drawRect(pixelRect, _clearPaint);
          }
        }

        _compositePaint
          ..blendMode = BlendMode.srcOver
          ..filterQuality = slotWorld.renderScale == 1.0
              ? FilterQuality.none
              : slotWorld.scaledFilterQuality;
        int? imgWidth;
        int? imgHeight;
        try {
          imgWidth = image.width;
          imgHeight = image.height;
        } on Object {
          imgWidth = null;
          imgHeight = null;
        }
        if (imgWidth != null && imgHeight != null) {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, imgWidth.toDouble(), imgHeight.toDouble()),
            pixelRect,
            _compositePaint,
          );
        }
        canvas.restore();
        image.dispose();

        if (slot.borderColor case final border? when slot.borderWidth > 0) {
          _borderPaint
            ..color = border
            ..strokeWidth = slot.borderWidth;
          canvas.drawRect(
            pixelRect.deflate(slot.borderWidth * 0.5),
            _borderPaint,
          );
        }
        rendered++;
      }
      _lastRenderedSlotCount = rendered;
      return rendered;
    } finally {
      if (openedEmbedded) {
        embedded?.close();
      }
      if (openedDevice) {
        resolvedDevice?.end();
      }
    }
  }

  /// Renders all active slots offscreen into an independent [Image] of
  /// [canvasSize] (scaled by [pixelRatio]).
  ///
  /// The caller owns the returned [Image] and should `dispose()` it when done.
  Image renderOffscreen(
    Size canvasSize, {
    World3D? defaultWorld,
    GraphicsDevice? device,
    RenderContext3D? context,
    bool manageDeviceFrame = true,
    double pixelRatio = 1.0,
    Msaa msaa = Msaa.off,
  }) {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    if (pixelRatio != 1.0) {
      canvas.scale(pixelRatio, pixelRatio);
    }
    render(
      canvas,
      canvasSize,
      defaultWorld: defaultWorld,
      device: device,
      context: context,
      manageDeviceFrame: manageDeviceFrame,
      pixelRatio: pixelRatio,
      msaa: msaa,
    );
    final picture = recorder.endRecording();
    final wPx = math.max(1, (canvasSize.width * pixelRatio).round());
    final hPx = math.max(1, (canvasSize.height * pixelRatio).round());
    final img = picture.toImageSync(wPx, hPx);
    picture.dispose();
    return img;
  }

  static bool _rectContainsPoint(Rect rect, Vector2 point, Size canvasSize) {
    final withinX =
        point.x >= rect.left &&
        (point.x < rect.right ||
            (rect.right >= canvasSize.width - 1e-6 && point.x <= rect.right));
    final withinY =
        point.y >= rect.top &&
        (point.y < rect.bottom ||
            (rect.bottom >= canvasSize.height - 1e-6 &&
                point.y <= rect.bottom));
    return withinX && withinY;
  }
}

class _IndexedSlot(this.slot, this.order) {
  final CameraViewportSlot3D slot;
  final int order;
}
