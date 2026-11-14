import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart' hide Matrix4;
import 'package:flame/extensions.dart' hide Matrix4;
import 'package:flame/game.dart' hide Matrix4;
import 'package:flame/src/game/game_loop.dart';
import 'package:flame/src/game/proxy_canvas.dart';
import 'package:flame/src/game/widget_components.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' hide WidgetBuilder;
import 'package:meta/meta.dart';

/// A [RenderObjectWidget] that renders the [GameRenderBox].
///
/// This is the widget that is used by the [GameWidget] to ACTUALLY
/// render the game.
///
/// Its [children] are the widgets hosted by the [WidgetComponent]s that are
/// currently mounted in the game, each wrapped in a [WidgetComponentHost].
class const RenderGameWidget({
  required final Game game,
  required final bool addRepaintBoundary,
  required final HitTestBehavior behavior,
  super.children,
  super.key,
}) extends MultiChildRenderObjectWidget {
  @override
  RenderBox createRenderObject(BuildContext context) {
    return GameRenderBox(
      game,
      context,
      isRepaintBoundary: addRepaintBoundary,
      behavior: behavior,
    );
  }

  @override
  void updateRenderObject(BuildContext context, GameRenderBox renderObject) {
    renderObject
      ..game = game
      ..buildContext = context
      ..isRepaintBoundary = addRepaintBoundary
      ..behavior = behavior
      ..syncDisplayMetricsFromView();
  }
}

class GameRenderBox(
  var Game _game,
  var BuildContext buildContext, {
  required var bool _isRepaintBoundary,
  var HitTestBehavior behavior = HitTestBehavior.opaque,
}) extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, WidgetComponentParentData>,
        WidgetsBindingObserver {
  GameLoop? gameLoop;

  Game get game => _game;

  set game(Game value) {
    // Identities are equal, no need to update.
    if (_game == value) {
      return;
    }

    if (attached) {
      _detachGame();
    }

    _game = value;

    if (attached) {
      _attachGame(owner!);
    }
  }

  set isRepaintBoundary(bool value) {
    if (_isRepaintBoundary == value) {
      return;
    }
    _isRepaintBoundary = value;
    markNeedsCompositingBitsUpdate();
  }

  @override
  bool get isRepaintBoundary => _isRepaintBoundary;

  final Map<WidgetComponent, RenderBox> _childByComponent = {};

  /// The widgets that were painted during the last paint, in paint order.
  final List<_PaintedWidget> _paintedWidgets = [];

  bool _isPerformingLayout = false;
  bool _paintedStateUpdateScheduled = false;

  PaintingContext? _paintingContext;
  ProxyCanvas? _canvas;

  /// The transform from this render box's local coordinates to the coordinate
  /// space of the canvas the game was rendered on during the last paint,
  /// inverted so that widget transforms can be brought back to local space.
  Matrix4? _inverseBaseTransform;
  Matrix4? _baseTransform;

  /// The components whose widgets were painted during the last paint, in
  /// paint order.
  @visibleForTesting
  List<WidgetComponent> get paintedWidgetComponents {
    return [for (final painted in _paintedWidgets) painted.component];
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! WidgetComponentParentData) {
      child.parentData = WidgetComponentParentData();
    }
  }

  /// Requests a relayout of the hosted widgets, for example because the size
  /// of a [WidgetComponent] changed. Ignored while the layout is running,
  /// since the sizes set during layout are already the laid out ones.
  @internal
  void markNeedsWidgetLayout() {
    if (!_isPerformingLayout) {
      markNeedsLayout();
    }
  }

  @override
  void performLayout() {
    _isPerformingLayout = true;
    try {
      _childByComponent.clear();
      _paintedWidgets.clear();
      final gameSize = size.toVector2();
      var child = firstChild;
      while (child != null) {
        final parentData = child.parentData! as WidgetComponentParentData;
        final component = parentData.component;
        if (component == null) {
          child.layout(BoxConstraints.tight(Size.zero));
        } else {
          _childByComponent[component] = child;
          child.layout(
            component.constraintsFor(gameSize),
            parentUsesSize: true,
          );
          component.adoptWidgetSize(child.size);
        }
        child = parentData.nextSibling;
      }
    } finally {
      _isPerformingLayout = false;
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _attachGame(owner);
  }

  void _attachGame(PipelineOwner owner) {
    game.attach(owner, this);
    syncDisplayMetricsFromView();

    final gameLoop = this.gameLoop = GameLoop(
      gameLoopCallback,
      minFrameIntervalGetter: () => game.minFrameIntervalSeconds,
      vsyncDivisorGetter: () => game.effectiveVsyncDivisor,
    );

    if (!game.isPaused) {
      gameLoop.start();
    }

    _bindLifecycleListener();
  }

  @override
  void detach() {
    super.detach();
    _detachGame();
  }

  void _detachGame() {
    _semanticsNodesByComponent.clear();
    game.detach();
    gameLoop?.dispose();
    gameLoop = null;
    _unbindLifecycleListener();
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    game.recordRawPointerEvent(event);
    super.handleEvent(event, entry);
  }

  final Stopwatch _telemetryStopwatch = Stopwatch();

  void gameLoopCallback(double dt) {
    assert(attached);
    if (!attached) {
      return;
    }
    game.advanceAdaptivePacing(dt);
    if (game.collectRenderTelemetry && game is! FlameGame) {
      _telemetryStopwatch
        ..reset()
        ..start();
      try {
        game.update(dt);
      } finally {
        _telemetryStopwatch.stop();
        game.renderTelemetry.recordUpdateMicros(
          _telemetryStopwatch.elapsedMicroseconds,
        );
      }
    } else {
      game.update(dt);
    }
    if (game.shouldRenderThisTick(dt)) {
      markNeedsPaint();
    }
    if ((SemanticsComponent.mountedCount > 0 ||
            _semanticsNodesByComponent.isNotEmpty) &&
        Transform2D.globalMutationCount != _lastSemanticsTxCount) {
      markNeedsSemanticsUpdate();
    }
  }

  @override
  bool hitTestSelf(Offset position) {
    // `translucent` means "hit me, and let the widgets behind me be hit too",
    // so the game is always a hit; the passthrough is Flutter's job. Only
    // `deferToChild` asks the game whether this particular point is its own.
    if (behavior != HitTestBehavior.deferToChild) {
      return true;
    }
    return game.containsEventHandlerAt(position.toVector2());
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final baseTransform = _baseTransform;
    if (baseTransform == null) {
      return false;
    }
    final canvasPosition = MatrixUtils.transformPoint(baseTransform, position);
    for (var i = _paintedWidgets.length - 1; i >= 0; i--) {
      final painted = _paintedWidgets[i];
      if (!painted.clip.contains(canvasPosition)) {
        continue;
      }
      final isHit = result.addWithPaintTransform(
        transform: painted.localTransform,
        position: position,
        hitTest: (result, transformed) {
          return painted.child.hitTest(result, position: transformed);
        },
      );
      if (isHit) {
        return true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final paintTransform =
        (child.parentData! as WidgetComponentParentData).paintTransform;
    if (paintTransform != null) {
      transform.multiply(paintTransform);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paintedWidgets.clear();
    game.onFrameRendered();
    final collectTelemetry = game.collectRenderTelemetry;
    if (firstChild == null) {
      _baseTransform = null;
      _inverseBaseTransform = null;
      context.canvas.save();
      context.canvas.translate(offset.dx, offset.dy);
      if (collectTelemetry && game is! FlameGame) {
        game.renderTelemetry.beginRenderFrame();
        TelemetryCanvas.pushActiveTelemetry(game.renderTelemetry);
        final tc = game.rootTelemetryCanvas
          ..bind(context.canvas, game.renderTelemetry);
        _telemetryStopwatch
          ..reset()
          ..start();
        try {
          game.render(tc);
        } finally {
          _telemetryStopwatch.stop();
          tc.unbind();
          TelemetryCanvas.popActiveTelemetry();
          game.renderTelemetry.endRenderFrame(
            renderMicros: _telemetryStopwatch.elapsedMicroseconds,
          );
        }
      } else {
        game.render(context.canvas);
      }
      context.canvas.restore();
      return;
    }

    for (final child in _childByComponent.values) {
      (child.parentData! as WidgetComponentParentData).paintedThisFrame = false;
    }
    final ui.Canvas underlyingCanvas;
    if (collectTelemetry) {
      game.renderTelemetry.beginRenderFrame();
      TelemetryCanvas.pushActiveTelemetry(game.renderTelemetry);
      underlyingCanvas = game.rootTelemetryCanvas
        ..bind(context.canvas, game.renderTelemetry);
      _telemetryStopwatch
        ..reset()
        ..start();
    } else {
      underlyingCanvas = context.canvas;
    }
    final canvas = ProxyCanvas(underlyingCanvas);
    _paintingContext = context;
    _canvas = canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    final baseTransform = Matrix4.fromFloat64List(canvas.getTransform());
    _baseTransform = baseTransform;
    _inverseBaseTransform = Matrix4.tryInvert(baseTransform);
    try {
      game.render(canvas);
    } finally {
      canvas.restore();
      _paintingContext = null;
      _canvas = null;
      if (collectTelemetry) {
        _telemetryStopwatch.stop();
        game.rootTelemetryCanvas.unbind();
        TelemetryCanvas.popActiveTelemetry();
        game.renderTelemetry.endRenderFrame(
          renderMicros: _telemetryStopwatch.elapsedMicroseconds,
        );
      }
    }
    _updatePaintedState();
  }

  /// Clears the paint transform of the children that were not painted and
  /// tells the components whose painted state changed, after the frame, so
  /// that their hosts can rebuild.
  void _updatePaintedState() {
    var needsUpdate = false;
    for (final entry in _childByComponent.entries) {
      final parentData = entry.value.parentData! as WidgetComponentParentData;
      if (!parentData.paintedThisFrame) {
        parentData.paintTransform = null;
      }
      if (parentData.paintedThisFrame != entry.key.isPainted) {
        needsUpdate = true;
      }
    }
    if (!needsUpdate || _paintedStateUpdateScheduled) {
      return;
    }
    _paintedStateUpdateScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _paintedStateUpdateScheduled = false;
      for (final entry in _childByComponent.entries) {
        final parentData = entry.value.parentData;
        if (parentData is WidgetComponentParentData) {
          entry.key.markPainted(isPainted: parentData.paintedThisFrame);
        }
      }
    });
  }

  /// Paints the widget hosted by [component] at the current transform of
  /// [canvas], as part of the game render pass.
  ///
  /// Does nothing when [canvas] is not the canvas of the current paint, which
  /// is the case when the component tree is being rendered somewhere else,
  /// for example into a snapshot, or when the widget has already been painted
  /// during this paint.
  @internal
  void paintWidgetComponent(WidgetComponent component, ui.Canvas canvas) {
    final context = _paintingContext;
    final proxyCanvas = _canvas;
    final inverseBaseTransform = _inverseBaseTransform;
    if (context == null ||
        proxyCanvas == null ||
        inverseBaseTransform == null ||
        !identical(canvas, proxyCanvas)) {
      return;
    }
    final child = _childByComponent[component];
    if (child == null) {
      return;
    }
    final parentData = child.parentData! as WidgetComponentParentData;
    if (parentData.paintedThisFrame) {
      return;
    }

    final transform = Matrix4.fromFloat64List(canvas.getTransform());
    if (transform.determinant() == 0) {
      return;
    }
    final clip = canvas.getDestinationClipBounds();
    final localTransform = inverseBaseTransform.multiplied(transform);
    parentData
      ..paintTransform = localTransform
      ..paintedThisFrame = true;
    _paintedWidgets.add(
      _PaintedWidget(
        component: component,
        child: child,
        clip: clip,
        localTransform: localTransform,
      ),
    );

    if (!child.needsCompositing) {
      context.paintChild(child, Offset.zero);
      return;
    }

    if (_isClippedByFlame(clip)) {
      context.pushClipRect(true, Offset.zero, clip, (context, offset) {
        context.pushTransform(true, offset, transform, _paintChildOf(child));
      });
    } else {
      context.pushTransform(true, Offset.zero, transform, _paintChildOf(child));
    }
    if (game.collectRenderTelemetry) {
      game.rootTelemetryCanvas.bind(context.canvas, game.renderTelemetry);
      proxyCanvas.swap(game.rootTelemetryCanvas);
    } else {
      proxyCanvas.swap(context.canvas);
    }
  }

  /// Whether [clip], given in the coordinate space of the canvas that the game
  /// is rendered on, cuts into the area of this render box.
  bool _isClippedByFlame(Rect clip) {
    final bounds = MatrixUtils.transformRect(
      _baseTransform!,
      Offset.zero & size,
    );
    const tolerance = 0.001;
    return clip.left > bounds.left + tolerance ||
        clip.top > bounds.top + tolerance ||
        clip.right < bounds.right - tolerance ||
        clip.bottom < bounds.bottom - tolerance;
  }

  static PaintingContextCallback _paintChildOf(RenderBox child) {
    return (context, offset) => context.paintChild(child, offset);
  }

  bool _timingsCallbackRegistered = false;

  void _onPlatformFrameTimings(List<FrameTiming> timings) {
    final g = _game;
    final wantsTimings =
        g.collectRenderTelemetry ||
        (g is FlameGame && g.qualityGovernor.enabled);
    if (!wantsTimings || timings.isEmpty) {
      return;
    }
    final targetHz = g.effectiveTargetFps ?? g.displayRefreshRate;
    final budgetMs = targetHz > 0.0 ? 1000.0 / targetHz : 16.67;
    for (var i = 0; i < timings.length; i++) {
      final t = timings[i];
      g.renderTelemetry.recordPlatformFrameTiming(
        buildMicros: t.buildDuration.inMicroseconds,
        rasterMicros: t.rasterDuration.inMicroseconds,
        totalSpanMicros: t.totalSpan.inMicroseconds,
        targetBudgetMs: budgetMs,
      );
    }
  }

  /// Synchronizes `FlutterView.devicePixelRatio` and `display.refreshRate` into
  /// [game].
  @internal
  void syncDisplayMetricsFromView() {
    ui.FlutterView? view;
    if (buildContext case final Element el when el.mounted) {
      view = View.maybeOf(el);
    }
    view ??= ui.PlatformDispatcher.instance.views.firstOrNull;
    if (view != null) {
      game.updatePlatformDisplayMetrics(
        devicePixelRatio: view.devicePixelRatio,
        refreshRate: view.display.refreshRate,
      );
    }
  }

  void _bindLifecycleListener() {
    WidgetsBinding.instance.addObserver(this);
    if (!_timingsCallbackRegistered) {
      _timingsCallbackRegistered = true;
      SchedulerBinding.instance.addTimingsCallback(_onPlatformFrameTimings);
    }
  }

  void _unbindLifecycleListener() {
    WidgetsBinding.instance.removeObserver(this);
    if (_timingsCallbackRegistered) {
      _timingsCallbackRegistered = false;
      SchedulerBinding.instance.removeTimingsCallback(_onPlatformFrameTimings);
    }
  }

  final Map<Component, SemanticsNode> _semanticsNodesByComponent =
      <Component, SemanticsNode>{};
  int _lastSemanticsTxCount = -1;
  static final Vector2 _semPtScratch = Vector2.zero();

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true;
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    final g = _game;
    _lastSemanticsTxCount = Transform2D.globalMutationCount;
    if (g is! FlameGame || !hasSize) {
      _semanticsNodesByComponent.clear();
      node.updateWith(
        config: config,
        childrenInInversePaintOrder: children.toList(growable: false),
      );
      return;
    }

    final boxBounds = Offset.zero & size;
    final collected = <({SemanticsComponent comp, Rect rect})>[];
    final cam = g.camera;
    final activeWorld = cam.world;

    // Paint order bottom-to-top: backdrop -> world -> viewfinder -> viewport
    // -> other root children.
    if (activeWorld != null && activeWorld.isMounted) {
      _collectSemanticsInSubtree(
        cam.backdrop,
        collected,
        mode: _SemanticsSpaceMode.viewport,
        camera: cam,
        clipBounds: boxBounds,
      );
      _collectSemanticsInSubtree(
        activeWorld,
        collected,
        mode: _SemanticsSpaceMode.world,
        camera: cam,
        clipBounds: boxBounds,
      );
      _collectSemanticsInSubtree(
        cam.viewfinder,
        collected,
        mode: _SemanticsSpaceMode.world,
        camera: cam,
        clipBounds: boxBounds,
      );
      _collectSemanticsInSubtree(
        cam.viewport,
        collected,
        mode: _SemanticsSpaceMode.viewport,
        camera: cam,
        clipBounds: boxBounds,
      );
    }

    for (final rootChild in g.children) {
      if (identical(rootChild, cam) || identical(rootChild, activeWorld)) {
        continue;
      }
      _collectSemanticsInSubtree(
        rootChild,
        collected,
        mode: _SemanticsSpaceMode.canvas,
        camera: cam,
        clipBounds: boxBounds,
      );
    }

    if (collected.isEmpty) {
      _semanticsNodesByComponent.clear();
      node.updateWith(
        config: config,
        childrenInInversePaintOrder: children.toList(growable: false),
      );
      return;
    }

    final activeSet = <Component>{};
    final orderedNodes = <SemanticsNode>[...children];

    // Flutter expects `childrenInInversePaintOrder` (front-most HUD first).
    for (var i = collected.length - 1; i >= 0; i--) {
      final entry = collected[i];
      final comp = entry.comp;
      activeSet.add(comp);
      final semNode = _semanticsNodesByComponent.putIfAbsent(
        comp,
        SemanticsNode.new,
      );
      semNode
        ..rect = entry.rect
        ..transform = null;
      semNode.updateWith(config: comp.buildSemanticsConfiguration());
      orderedNodes.add(semNode);
    }

    _semanticsNodesByComponent.removeWhere(
      (comp, _) => !activeSet.contains(comp),
    );

    node.updateWith(
      config: config,
      childrenInInversePaintOrder: orderedNodes,
    );
  }

  void _collectSemanticsInSubtree(
    Component current,
    List<({SemanticsComponent comp, Rect rect})> out, {
    required _SemanticsSpaceMode mode,
    required CameraComponent camera,
    required Rect clipBounds,
  }) {
    if (!current.isMounted ||
        current.isRemoving ||
        !current.isActiveForCurrentGraphicsTier) {
      return;
    }
    if (current is HasVisibility && !current.isVisible) {
      return;
    }
    if (mode == _SemanticsSpaceMode.world &&
        (current.cameraMask & camera.cameraMask) == 0) {
      return;
    }

    if (current is SemanticsComponent && !current.semanticsExcluded) {
      final projected = _projectSemanticsRect(
        current,
        mode: mode,
        camera: camera,
        clipBounds: clipBounds,
      );
      if (projected != null && !projected.isEmpty) {
        out.add((comp: current, rect: projected));
      }
    }

    if (current.hasChildren) {
      for (final child in current.children) {
        _collectSemanticsInSubtree(
          child,
          out,
          mode: mode,
          camera: camera,
          clipBounds: clipBounds,
        );
      }
    }
  }

  Rect? _projectSemanticsRect(
    SemanticsComponent comp, {
    required _SemanticsSpaceMode mode,
    required CameraComponent camera,
    required Rect clipBounds,
  }) {
    Rect spaceRect;
    if (comp is PositionComponent) {
      final posComp = comp as PositionComponent;
      final explicit = comp.semanticsLocalBounds;
      if (explicit != null) {
        final m = posComp.worldTransformMatrix;
        final (x0, y0) = m.transformXY(explicit.left, explicit.top);
        final (x1, y1) = m.transformXY(explicit.right, explicit.top);
        final (x2, y2) = m.transformXY(explicit.right, explicit.bottom);
        final (x3, y3) = m.transformXY(explicit.left, explicit.bottom);
        spaceRect = Rect.fromLTRB(
          math.min(math.min(x0, x1), math.min(x2, x3)),
          math.min(math.min(y0, y1), math.min(y2, y3)),
          math.max(math.max(x0, x1), math.max(x2, x3)),
          math.max(math.max(y0, y1), math.max(y2, y3)),
        );
      } else {
        spaceRect = posComp.toAbsoluteRect();
      }
    } else {
      spaceRect = comp.semanticsLocalBounds ?? const Rect.fromLTWH(0, 0, 1, 1);
    }

    Rect canvasRect;
    switch (mode) {
      case _SemanticsSpaceMode.canvas:
        canvasRect = spaceRect;
      case _SemanticsSpaceMode.viewport:
        _semPtScratch.setValues(spaceRect.left, spaceRect.top);
        camera.viewport.localToGlobal(_semPtScratch, output: _semPtScratch);
        final x0 = _semPtScratch.x;
        final y0 = _semPtScratch.y;
        _semPtScratch.setValues(spaceRect.right, spaceRect.bottom);
        camera.viewport.localToGlobal(_semPtScratch, output: _semPtScratch);
        final x1 = _semPtScratch.x;
        final y1 = _semPtScratch.y;
        canvasRect = Rect.fromLTRB(
          math.min(x0, x1),
          math.min(y0, y1),
          math.max(x0, x1),
          math.max(y0, y1),
        );
      case _SemanticsSpaceMode.world:
        _semPtScratch.setValues(spaceRect.left, spaceRect.top);
        camera.localToGlobal(_semPtScratch, output: _semPtScratch);
        final x0 = _semPtScratch.x;
        final y0 = _semPtScratch.y;
        _semPtScratch.setValues(spaceRect.right, spaceRect.top);
        camera.localToGlobal(_semPtScratch, output: _semPtScratch);
        final x1 = _semPtScratch.x;
        final y1 = _semPtScratch.y;
        _semPtScratch.setValues(spaceRect.right, spaceRect.bottom);
        camera.localToGlobal(_semPtScratch, output: _semPtScratch);
        final x2 = _semPtScratch.x;
        final y2 = _semPtScratch.y;
        _semPtScratch.setValues(spaceRect.left, spaceRect.bottom);
        camera.localToGlobal(_semPtScratch, output: _semPtScratch);
        final x3 = _semPtScratch.x;
        final y3 = _semPtScratch.y;
        canvasRect = Rect.fromLTRB(
          math.min(math.min(x0, x1), math.min(x2, x3)),
          math.min(math.min(y0, y1), math.min(y2, y3)),
          math.max(math.max(x0, x1), math.max(x2, x3)),
          math.max(math.max(y0, y1), math.max(y2, y3)),
        );
    }

    if (!canvasRect.overlaps(clipBounds)) {
      return null;
    }
    final clipped = canvasRect.intersect(clipBounds);
    if (clipped.width <= 0.0 || clipped.height <= 0.0) {
      return null;
    }
    return clipped;
  }

  @override
  void didChangeMetrics() {
    syncDisplayMetricsFromView();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        game.cancelGesturesOnLifecyclePause) {
      game.cancelActivePointerGestures();
    }
    game.lifecycleStateChange(state);
  }
}

enum _SemanticsSpaceMode() {
  canvas,
  viewport,
  world,
}

class _PaintedWidget({
  required final WidgetComponent component,
  required final RenderBox child,

  /// The clip that was active when the widget was painted, in the coordinate
  /// space of the canvas the game was rendered on.
  required final Rect clip,

  /// The transform from the widget's coordinates to the local coordinates of
  /// the [GameRenderBox].
  required final Matrix4 localTransform,
});
