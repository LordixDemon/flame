import 'dart:collection' show UnmodifiableListView;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart' show Component;
import 'package:flame/game.dart' show Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/graphics/embedded_renderer.dart';

part 'camera_stack_3d_renderer.dart';

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
  ///
  /// The same as [depthOnly]: every slot renders into an image of its own,
  /// with a depth buffer of its own, so no depth is kept from the slots
  /// drawn before it.
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
  int _nextOrder = 0;
  int _lastRenderedSlotCount = 0;
  final Map<World3D, Game?> _cachedSlotGames = Map.identity();
  Game? _cachedFallbackGame;

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
    _ensureSorted();
    return UnmodifiableListView([for (final entry in _entries) entry.slot]);
  }

  /// Sorts [_entries] by priority, then insertion order, in place: priorities
  /// may change at any time, and an insertion sort of an already sorted list
  /// costs one comparison per slot and allocates nothing.
  void _ensureSorted() {
    final entries = _entries;
    for (var i = 1; i < entries.length; i++) {
      final entry = entries[i];
      var j = i - 1;
      while (j >= 0 && _after(entries[j], entry)) {
        entries[j + 1] = entries[j];
        j--;
      }
      entries[j + 1] = entry;
    }
  }

  static bool _after(_IndexedSlot a, _IndexedSlot b) {
    final pa = a.slot.priority;
    final pb = b.slot.priority;
    return pa > pb || (pa == pb && a.order > b.order);
  }

  /// Appends [slot] to this stack.
  void addSlot(CameraViewportSlot3D slot) {
    _entries.add(_IndexedSlot(slot, _nextOrder++));
  }

  /// Removes [slot] from this stack, returning `true` if it was present.
  bool removeSlot(CameraViewportSlot3D slot) {
    final idx = _entries.indexWhere((e) => identical(e.slot, slot));
    if (idx < 0) {
      return false;
    }
    _entries.removeAt(idx);
    return true;
  }

  /// Removes all slots from this stack and clears cached game references.
  void clear() {
    _entries.clear();
    _cachedSlotGames.clear();
    _cachedFallbackGame = null;
  }

  /// Clears cached [Game] lookups held by this stack (call on detach/remove if
  /// slots move between games).
  void clearGameCache() {
    _cachedSlotGames.clear();
    _cachedFallbackGame = null;
  }

  Game? _gameFor(World3D world) {
    final cached = _cachedSlotGames[world];
    if (cached != null && world.isMounted) {
      if (cached case final Component c when !c.isMounted) {
        // Stale game is no longer mounted; resolve again below.
      } else {
        return cached;
      }
    }
    final resolved = world.findGame();
    if (resolved != null) {
      _cachedSlotGames[world] = resolved;
    } else {
      _cachedSlotGames.remove(world);
    }
    return resolved;
  }

  /// Advances unmounted cameras in this stack by [dt].
  ///
  /// When one of them moved (its [CameraComponent3D.version] changed), it
  /// notifies a visual change so that a game whose `idleRenderMode` skips
  /// unchanged frames renders the next one.
  void update(double dt) {
    var moved = false;
    for (final entry in _entries) {
      final slot = entry.slot;
      final camera = slot.camera;
      if (slot.enabled && !camera.isMounted) {
        camera.update(dt);
        final version = camera.version;
        if (version != entry.cameraVersion) {
          entry.cameraVersion = version;
          moved = true;
        }
      }
    }
    if (moved) {
      Game.notifyVisualMutation();
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
    _ensureSorted();
    for (var i = _entries.length - 1; i >= 0; i--) {
      final slot = _entries[i].slot;
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
  /// slot's [World3D], hitting only what the slot's camera draws: hidden
  /// components and components (or ancestors) whose
  /// [Component3D.cameraMask] shares no bit with the camera's are skipped,
  /// see [World3D.raycast].
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
    final hit = targetWorld.raycast(
      picked.worldRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
      filter: filter,
      cameraMask: picked.camera.cameraMask,
    );
    return (picked, hit);
  }

  /// Renders every enabled [CameraViewportSlot3D] in ascending priority order
  /// onto [canvas] within [canvasSize].
  ///
  /// Returns the number of slots rendered.
  ///
  /// Each slot renders into a render target the stack keeps for it from
  /// frame to frame (created again when its size or format changes), and
  /// the image is drawn on [canvas] in the same frame.
  int render(
    Canvas canvas,
    Size canvasSize, {
    World3D? defaultWorld,
    GraphicsDevice? device,
    RenderContext3D? context,
    bool manageDeviceFrame = false,
    double pixelRatio = 1.0,
    Msaa msaa = Msaa.off,
  }) => _renderImpl(
    canvas,
    canvasSize,
    defaultWorld: defaultWorld,
    device: device,
    context: context,
    manageDeviceFrame: manageDeviceFrame,
    pixelRatio: pixelRatio,
    msaa: msaa,
    keepTargets: true,
  );

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
    // The picture is rasterized later: its slot images get render targets
    // of their own, so that no later render overwrites them before.
    _renderImpl(
      canvas,
      canvasSize,
      defaultWorld: defaultWorld,
      device: device,
      context: context,
      manageDeviceFrame: manageDeviceFrame,
      pixelRatio: pixelRatio,
      msaa: msaa,
      keepTargets: false,
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
