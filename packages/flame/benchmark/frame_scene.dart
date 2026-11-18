import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/particles.dart';
import 'package:flame/rendering.dart';
import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/painting.dart' show EdgeInsets, TextStyle;

import 'common.dart';

/// A board-game-like scene of a few hundred components, built to measure what
/// the engine itself costs per frame in a typical mobile game.
///
/// It has the shape of a turn-based board game running at 120 Hz:
///
/// - a [World] with its spatial index, ticked with a fixed time step;
/// - a ring of tiles in four [SpatialCullGroup] sectors, each tile with a
///   child marker;
/// - buildings on the tiles ([MultiPassComponent], tap and hover callbacks),
///   with a roof and a flag, a fifth of the flags pulsing with a
///   [ScaleEffect];
/// - four pieces that hop from tile to tile with an [ArcMoveEffect] every
///   0.18 s (one of them glides with a [WaypointPathEffect]), with a bobbing
///   body, a [CameraBillboard] name chip, a [CameraBillboard] and
///   [ViewportClampedPin] bubble, a [PaintDecorator] and a
///   [RibbonTrailComponent] each;
/// - a [ParticleBatchGroup] with continuous emitters and pooled bursts,
///   under a [HasTimeScale] layer;
/// - price chips that draw text with a shared [TextPaint];
/// - a full-board drag area and a heads-up display in the viewport;
/// - a camera that pans and zooms every frame, idle rendering on demand with
///   dirty version sources, and frame telemetry.
///
/// [step], [renderFrame], [renderEmissivePass], [hover] and [hitTest] are the
/// phases of a frame, so that each can be timed (and its allocations counted)
/// on its own.
class FrameSceneGame()
    extends FlameGame<FrameSceneWorld>
    with HasFrameTelemetry<FrameSceneWorld> {
  this : super(world: FrameSceneWorld()) {
    fixedTimeStep = 1 / 120;
    idleFps = 30;
    idleTimeoutSeconds = 3;
    idleRenderMode = IdleRenderMode.onDemandWhenIdle;
    coalesceMouseHover = true;
    registerDirtyVersionSource(() => _versionA);
    registerDirtyVersionSource(() => _versionB);
  }

  /// The size of the canvas the scene is laid out for: a phone in
  /// landscape, in logical pixels.
  static final Vector2 screenSize = Vector2(844, 390);

  int _versionA = 0;
  final int _versionB = 0;
  double _time = 0;
  int _frame = 0;
  final ui.Rect _cullRect = const ui.Rect.fromLTWH(0, 0, 844, 390);
  final List<TextComponent> _hud = [];

  /// Creates the scene and brings it to a mounted state, with every
  /// component loaded.
  static Future<FrameSceneGame> create() async {
    final game = FrameSceneGame();
    await mountGame(game, size: screenSize);
    // Lets the first effects and bursts mount.
    for (var i = 0; i < 4; i++) {
      game.step();
    }
    return game;
  }

  @override
  Future<void> onLoad() async {
    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.zoom = 0.9;
    for (var i = 0; i < 3; i++) {
      final text = TextComponent(
        text: 'hud $i',
        textRenderer: _hudPaint,
        position: Vector2(12, 12 + 18.0 * i),
      );
      _hud.add(text);
    }
    camera.viewport.addAll(_hud);
  }

  static final TextPaint _hudPaint = TextPaint(
    style: const TextStyle(fontSize: 12, color: ui.Color(0xFFFFFFFF)),
  );

  /// Advances the scene by one 120 Hz frame, the way the game loop does:
  /// [update] and then the decision whether this frame paints.
  @pragma('vm:never-inline')
  bool step([double dt = 1 / 120]) {
    _time += dt;
    _frame++;
    // The camera follows the action: it pans and zooms a little every frame.
    camera.viewfinder.position.setValues(
      math.sin(_time * 0.9) * 60,
      math.cos(_time * 0.6) * 30,
    );
    camera.viewfinder.zoom = 0.9 + 0.08 * math.sin(_time * 0.5);
    if (_frame % 30 == 0) {
      _versionA++;
      _hud[0].text = 'frame ${_frame ~/ 30}';
    }
    advanceAdaptivePacing(dt);
    update(dt);
    return shouldRenderThisTick(dt);
  }

  /// Draws one frame into a picture, the way `GameRenderBox.paint` does, and
  /// throws the picture away.
  @pragma('vm:never-inline')
  void renderFrame() {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, _cullRect);
    onFrameRendered();
    render(canvas);
    recorder.endRecording().dispose();
  }

  /// Draws the auxiliary pass that a post process such as
  /// `DualPassShaderPostProcess` draws for its glow mask: the scene again,
  /// in the exclusive [RenderPass.emissiveMask], where only
  /// [MultiPassComponent]s paint.
  @pragma('vm:never-inline')
  void renderEmissivePass() {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, _cullRect);
    CameraComponent.pushRenderPass(RenderPass.emissiveMask);
    try {
      camera.renderTree(canvas);
    } finally {
      CameraComponent.popRenderPass();
    }
    recorder.endRecording().dispose();
  }

  final Vector2 _hoverPosition = Vector2.zero();

  /// Moves the mouse over the scene: one hover event that the next [step]
  /// dispatches (hover events are coalesced, one per frame).
  @pragma('vm:never-inline')
  void hover(double x, double y) {
    _hoverPosition.setValues(x, y);
    mouseDetector?.call(
      PointerHoverEvent(position: ui.Offset(x, y)),
    );
    flushPendingMouseHover();
  }

  /// Hit-tests the point like a tap does, returning how many components are
  /// under it.
  @pragma('vm:never-inline')
  int hitTest(Vector2 canvasPoint) {
    var count = 0;
    for (final _ in componentsAtPoint(canvasPoint)) {
      count++;
    }
    return count;
  }
}

/// The world of [FrameSceneGame].
class FrameSceneWorld() extends World with HasFixedUpdate {
  this : super(spatialIndexEnabled: true);

  static const int tileCount = 40;
  static const double _ringWidth = 760;
  static const double _ringHeight = 380;

  final List<Vector2> tileCenters = [];
  late final ParticleBatchGroup particles;
  final math.Random _random = math.Random(7);

  /// The simulated time, advanced by the fixed step.
  double fixedTime = 0;
  double _burstTimer = 0;

  static final ComponentPool<ParticleEmitterComponent> _burstPool =
      ComponentPool<ParticleEmitterComponent>(
        factory: () => ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 16,
            bursts: const [EmitterBurst(0, 12)],
            lifespan: (0.3, 0.5),
            speed: (30, 60),
            size: (3, 5),
          ),
          renderer: _softRenderer,
        ),
        maxSize: 16,
        initialSize: 4,
      );

  static final CircleParticleRenderer _softRenderer = CircleParticleRenderer(
    softness: 0.36,
    blendMode: ui.BlendMode.plus,
  );

  static final TextPaint _chipPaint = TextPaint(
    style: const TextStyle(fontSize: 9, color: ui.Color(0xFFFFF0C0)),
    cacheSize: 32,
  );

  @override
  Future<void> onLoad() async {
    for (var i = 0; i < tileCount; i++) {
      tileCenters.add(_ringPoint(i / tileCount));
    }

    add(_Backdrop());
    add(_Water());

    final ground = Component(priority: 10);
    final sectors = List.generate(
      4,
      (_) => SpatialCullGroup(staticBounds: true, cullPadding: 84),
    );
    for (var i = 0; i < tileCount; i++) {
      sectors[i * 4 ~/ tileCount].add(
        _Tile(position: tileCenters[i])..add(_TileMark()),
      );
    }
    ground.addAll(sectors);
    add(ground);

    final standing = Component(priority: 20);
    for (var i = 0; i < tileCount; i++) {
      final building = _Building(
        position: tileCenters[i] * 0.86,
      );
      final flag = _Flag();
      if (i % 5 == 0) {
        flag.add(
          ScaleEffect.by(
            Vector2.all(1.2),
            EffectController(duration: 0.6, infinite: true, alternate: true),
          ),
        );
      }
      building.addAll([_Roof(), flag]);
      standing.add(building);
    }
    add(standing);

    final pieceLayer = Component(priority: 30);
    for (var i = 0; i < 4; i++) {
      final piece = _Piece(
        index: i,
        start: i * (tileCount ~/ 4),
        glides: i == 3,
        position: tileCenters[i * (tileCount ~/ 4)].clone(),
      );
      pieceLayer.add(piece);
      pieceLayer.add(piece.trail);
    }
    add(pieceLayer);

    final effects = _EffectsLayer()..priority = 40;
    particles = ParticleBatchGroup();
    for (var i = 0; i < 4; i++) {
      particles.add(
        ParticleEmitterComponent(
          emitter: ParticleEmitter(
            maxParticles: 64,
            rate: 30,
            lifespan: (0.8, 1.2),
            speed: (10, 30),
            direction: -math.pi / 2,
            spread: 0.8,
            size: (4, 7),
          ),
          renderer: _softRenderer,
          removeOnFinish: false,
          position: tileCenters[i * 10 + 5].clone(),
        ),
      );
    }
    effects.add(particles);
    add(effects);

    final overlay = Component(priority: 50);
    for (var i = 0; i < 24; i++) {
      overlay.add(
        _PriceChip(
          text: '${(i + 1) * 120}',
          paint: _chipPaint,
          position: tileCenters[i] * 0.93,
        ),
      );
    }
    overlay.add(
      _Bubble(text: 'tooltip', paint: _chipPaint, position: Vector2(0, -40)),
    );
    add(overlay);

    add(_DragArea());
  }

  Vector2 _ringPoint(double t) {
    final angle = t * math.pi * 2;
    return Vector2(
      math.cos(angle) * _ringWidth / 2,
      math.sin(angle) * _ringHeight / 2,
    );
  }

  @override
  void fixedUpdate(double dt) {
    fixedTime += dt;
  }

  @override
  void update(double dt) {
    _burstTimer += dt;
    if (_burstTimer >= 0.3) {
      _burstTimer = 0;
      final burst = _burstPool.acquire()
        ..position.setFrom(tileCenters[_random.nextInt(tileCount)]);
      particles.add(burst);
    }
  }
}

class _Backdrop() extends PositionComponent {
  this
    : super(
        position: Vector2(-900, -500),
        size: Vector2(1800, 1000),
        priority: 0,
      );

  final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFF0E2940);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(size.toRect(), _paint);
  }
}

class _Water() extends PositionComponent {
  this
    : super(
        position: Vector2(-700, -380),
        size: Vector2(1400, 760),
        priority: 1,
      );

  final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFF145A7A);
  double _phase = 0;

  @override
  void update(double dt) {
    _phase += dt;
  }

  @override
  void render(ui.Canvas canvas) {
    final inset = 4 + math.sin(_phase) * 2;
    canvas.drawRRect(
      ui.RRect.fromLTRBR(
        inset,
        inset,
        size.x - inset,
        size.y - inset,
        const ui.Radius.circular(40),
      ),
      _paint,
    );
  }
}

class _Tile({super.position}) extends PositionComponent with PassiveComponent {
  this : super(size: Vector2(56, 28), anchor: Anchor.center);

  static final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFFCDB58A);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(size.toRect(), _paint);
  }
}

class _TileMark() extends PositionComponent with PassiveComponent {
  this : super(position: Vector2(22, 8), size: Vector2(12, 12));

  static final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFF7A5230);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawCircle(const ui.Offset(6, 6), 5, _paint);
  }
}

class _Building({super.position})
    extends PositionComponent
    with MultiPassComponent, TapCallbacks, HoverCallbacks {
  this
    : super(
        size: Vector2(40, 48),
        anchor: Anchor.bottomCenter,
        sortKey: position?.y,
      );

  static final ui.Paint _shadowPaint = ui.Paint()
    ..color = const ui.Color(0x44000000);
  static final ui.Paint _wallPaint = ui.Paint()
    ..color = const ui.Color(0xFFE8D8B8);
  static final ui.Paint _glowPaint = ui.Paint()
    ..color = const ui.Color(0xFFFFE080);

  @override
  List<RenderPass> get fallbackPasses => const [
    RenderPass.opaque,
    RenderPass.emissiveMask,
  ];

  @override
  void renderPass(ui.Canvas canvas, RenderPass pass) {
    if (pass == RenderPass.emissiveMask) {
      if (isHovered) {
        canvas.drawRect(const ui.Rect.fromLTWH(8, 8, 24, 10), _glowPaint);
      }
      return;
    }
    canvas.drawOval(const ui.Rect.fromLTWH(-4, 40, 48, 12), _shadowPaint);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 12, 40, 36), _wallPaint);
  }
}

class _Roof() extends PositionComponent with PassiveComponent {
  this : super(position: Vector2(-2, 0), size: Vector2(44, 14));

  static final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFFB04A30);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(size.toRect(), _paint);
  }
}

class _Flag() extends PositionComponent with PassiveComponent {
  this
    : super(
        position: Vector2(30, -10),
        size: Vector2(8, 10),
        anchor: Anchor.bottomLeft,
      );

  static final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFF3060D0);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRect(size.toRect(), _paint);
  }
}

/// A piece that walks around the ring, one tile per hop.
class _Piece({
  required final int index,
  required final int start,
  required final bool glides,
  super.position,
}) extends PositionComponent
    with TapCallbacks, HoverCallbacks
    implements ElevationTarget {
  this : super(anchor: Anchor.center, size: Vector2(44, 66)) {
    trail = RibbonTrailComponent(
      maxPoints: 24,
      lifetime: 0.36,
      startWidth: 12,
      startColor: const ui.Color(0xB8FFD27A),
      endColor: const ui.Color(0x00FFD27A),
      minPointDistance: 2.5,
      blendMode: ui.BlendMode.plus,
      priority: -1,
    );
    _bob.addAll([
      _PieceBody(),
      _Chip(text: 'P${index + 1}', paint: _tagPaint, position: Vector2(0, -52)),
      _Bubble(text: '!', paint: _tagPaint, position: Vector2(0, -70)),
    ]);
    add(_bob);
    if (index == 0) {
      decorator.addLast(PaintDecorator.tint(const ui.Color(0x553080FF)));
      decoratorBounds = const ui.Rect.fromLTRB(-28, -80, 72, 80);
    }
  }

  late int _tile = start;
  late final RibbonTrailComponent trail;
  final PositionComponent _bob = PositionComponent(position: Vector2(22, 33));
  double _time = 0;
  double _hopCooldown = 0;
  Effect? _move;

  static final TextPaint _tagPaint = TextPaint(
    style: const TextStyle(fontSize: 8, color: ui.Color(0xFFFFFFFF)),
  );

  double elevation = 0;

  @override
  void setElevation(double value) => elevation = value;

  FrameSceneWorld get _world => parent!.parent! as FrameSceneWorld;

  @override
  void update(double dt) {
    _time += dt;
    _bob.position.y = 33 - 0.8 * (1 - math.cos(_time * 3.7 + index));
    trail.addPointXY(position.x, position.y);
    _hopCooldown -= dt;
    if (_move == null && _hopCooldown <= 0) {
      _startMove();
    }
  }

  void _startMove() {
    final centers = _world.tileCenters;
    if (glides) {
      final waypoints = [
        for (var i = 1; i <= 3; i++)
          centers[(_tile + i) % centers.length].clone(),
      ];
      _tile = (_tile + 3) % centers.length;
      _move = WaypointPathEffect(
        waypoints,
        EffectController(duration: 0.9),
        tension: 0.5,
        onComplete: _onArrived,
      );
    } else {
      _tile = (_tile + 1) % centers.length;
      _move = ArcMoveEffect(
        centers[_tile].clone(),
        EffectController(duration: 0.18),
        arcHeight: 18,
        onComplete: _onArrived,
      );
    }
    add(_move!);
  }

  void _onArrived() {
    _move = null;
    _hopCooldown = glides ? 0.3 : 0.02;
  }

  @override
  bool containsLocalPoint(Vector2 point) =>
      point.x >= 0 && point.x <= 44 && point.y >= 0 && point.y <= 66;
}

class _PieceBody() extends PositionComponent with PassiveComponent {
  this : super(size: Vector2(20, 30), anchor: Anchor.bottomCenter);

  static final ui.Paint _paint = ui.Paint()..color = const ui.Color(0xFF2050C0);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawCircle(const ui.Offset(10, 8), 8, _paint);
    canvas.drawRect(const ui.Rect.fromLTWH(4, 14, 12, 16), _paint);
  }
}

/// A label with a rounded background that draws its text every frame.
class _Chip({
  required final String text,
  required final TextPaint paint,
  super.position,
}) extends PositionComponent with PassiveComponent, CameraBillboard {
  this : super(size: Vector2(28, 12), anchor: Anchor.center) {
    billboardZoomExponent = 0.42;
    minBillboardScale = 0.78;
    maxBillboardScale = 1.32;
  }

  static final ui.Paint _background = ui.Paint()
    ..color = const ui.Color(0xEE140C06);
  static final Vector2 _textOffset = Vector2(14, 6);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(size.toRect(), const ui.Radius.circular(4)),
      _background,
    );
    paint.render(canvas, text, _textOffset, anchor: Anchor.center);
  }
}

class _Bubble({
  required super.text,
  required super.paint,
  super.position,
}) extends _Chip with ViewportClampedPin {
  this {
    viewportPinMargin = const EdgeInsets.fromLTRB(16, 52, 16, 32);
  }
}

class _PriceChip({
  required final String text,
  required final TextPaint paint,
  super.position,
}) extends PositionComponent with PassiveComponent {
  this : super(size: Vector2(34, 13), anchor: Anchor.center);

  static final ui.Paint _background = ui.Paint()
    ..color = const ui.Color(0xD0101622);
  static final Vector2 _textOffset = Vector2(17, 6.5);

  @override
  void render(ui.Canvas canvas) {
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(size.toRect(), const ui.Radius.circular(3)),
      _background,
    );
    paint.render(canvas, text, _textOffset, anchor: Anchor.center);
  }
}

class _EffectsLayer() extends Component with CustomTraversal, HasTimeScale;

/// Covers the board and pans the camera when dragged; it never drops
/// anything.
class _DragArea()
    extends PositionComponent
    with TapCallbacks, DragCallbacks, PassiveComponent {
  this
    : super(
        position: Vector2(-450, -250),
        size: Vector2(900, 500),
        priority: 100,
      ) {
    isDropPayload = false;
  }

  @override
  void render(ui.Canvas canvas) {}
}
