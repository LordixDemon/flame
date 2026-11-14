import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:meta/meta.dart';

/// Zero-allocation per-frame CPU/GPU draw-call and timing telemetry counters
/// populated automatically by [TelemetryCanvas], `GameRenderBox`
/// (`FrameTiming`), and `FlameGame` when `Game.collectRenderTelemetry` is
/// enabled.
class RenderFrameTelemetry() {
  static const int _platformRingCapacity = 120;

  int _drawCalls = 0;
  int _atlasCalls = 0;
  int _verticesCalls = 0;
  int _saveLayerCalls = 0;
  int _pictureCalls = 0;
  int _clipCalls = 0;
  int _offscreenRasterizations = 0;
  int _updateMicros = 0;
  int _renderMicros = 0;

  int _lastDrawCalls = 0;
  int _lastAtlasCalls = 0;
  int _lastVerticesCalls = 0;
  int _lastSaveLayerCalls = 0;
  int _lastPictureCalls = 0;
  int _lastClipCalls = 0;
  int _lastOffscreenRasterizations = 0;

  // Hardware SchedulerBinding FrameTiming ring buffers (zero heap allocation).
  final Float32List _buildRingMs = Float32List(_platformRingCapacity);
  final Float32List _rasterRingMs = Float32List(_platformRingCapacity);
  final Float32List _spanRingMs = Float32List(_platformRingCapacity);
  final Float32List _percentileScratch = Float32List(_platformRingCapacity);
  int _platformCursor = 0;
  int _platformFilled = 0;
  int _lastBuildMicros = 0;
  int _lastRasterMicros = 0;
  int _lastTotalSpanMicros = 0;
  double _smoothedBuildMs = 0.0;
  double _smoothedRasterMs = 0.0;
  double _smoothedTotalSpanMs = 0.0;
  int _jankFrameCount = 0;

  /// Total canvas `draw*` calls submitted during the last completed frame
  /// (including offscreen `PostProcess` passes).
  int get drawCalls => _lastDrawCalls;

  /// `drawAtlas` / `drawRawAtlas` calls submitted during the last frame.
  int get atlasCalls => _lastAtlasCalls;

  /// `drawVertices` 3D/2D mesh calls submitted during the last frame.
  int get verticesCalls => _lastVerticesCalls;

  /// `saveLayer` offscreen compositing calls submitted during the last frame.
  int get saveLayerCalls => _lastSaveLayerCalls;

  /// `drawPicture` calls submitted during the last frame.
  int get pictureCalls => _lastPictureCalls;

  /// `clip*` calls submitted during the last frame.
  int get clipCalls => _lastClipCalls;

  /// Offscreen `Picture.toImageSync` rasterization passes executed during the
  /// last frame (for example by `PostProcess` / `DualPassShaderPostProcess`).
  int get offscreenRasterizations => _lastOffscreenRasterizations;

  /// CPU wall-clock duration (in microseconds) of the most recent `update`
  /// tick.
  int get updateMicros => _updateMicros;

  /// CPU wall-clock duration (in microseconds) of the most recent `render`
  /// pass.
  int get renderMicros => _renderMicros;

  /// Number of hardware `FrameTiming` samples collected (`0..120`).
  int get platformTimingSampleCount => _platformFilled;

  /// UI/build thread duration (in microseconds) from the latest `FrameTiming`.
  int get lastBuildMicros => _lastBuildMicros;

  /// GPU rasterizer duration (in microseconds) from the latest `FrameTiming`.
  int get lastRasterMicros => _lastRasterMicros;

  /// End-to-end VSync-to-raster total span (in microseconds) from the latest
  /// `FrameTiming`.
  int get lastTotalSpanMicros => _lastTotalSpanMicros;

  /// Exponentially smoothed UI/build duration in milliseconds.
  double get smoothedBuildMs => _smoothedBuildMs;

  /// Exponentially smoothed GPU raster duration in milliseconds.
  double get smoothedRasterMs => _smoothedRasterMs;

  /// Exponentially smoothed total frame span in milliseconds.
  double get smoothedTotalSpanMs => _smoothedTotalSpanMs;

  /// Total frames whose hardware span exceeded `1.5×` target frame budget.
  int get jankFrameCount => _jankFrameCount;

  /// Returns `true` when GPU rasterization dominates CPU UI/build work.
  bool get isGpuBound =>
      _platformFilled > 0 &&
      _smoothedRasterMs > 4.0 &&
      _smoothedRasterMs > _smoothedBuildMs * 1.15;

  /// 95th-percentile total frame span in milliseconds across the ring buffer.
  double get p95TotalSpanMs =>
      _percentileOf(_spanRingMs, _platformFilled, 0.95);

  /// 99th-percentile total frame span in milliseconds across the ring buffer.
  double get p99TotalSpanMs =>
      _percentileOf(_spanRingMs, _platformFilled, 0.99);

  /// 95th-percentile GPU raster duration in milliseconds across the ring
  /// buffer.
  double get p95RasterMs => _percentileOf(_rasterRingMs, _platformFilled, 0.95);

  double _percentileOf(Float32List ring, int count, double quantile) {
    if (count <= 0) {
      return 0.0;
    }
    for (var i = 0; i < count; i++) {
      _percentileScratch[i] = ring[i];
    }
    // Zero-allocation in-place insertion sort over <= 120 samples.
    for (var i = 1; i < count; i++) {
      final v = _percentileScratch[i];
      var j = i - 1;
      while (j >= 0 && _percentileScratch[j] > v) {
        _percentileScratch[j + 1] = _percentileScratch[j];
        j--;
      }
      _percentileScratch[j + 1] = v;
    }
    final idx = ((count - 1) * quantile.clamp(0.0, 1.0)).round().clamp(
      0,
      count - 1,
    );
    return _percentileScratch[idx];
  }

  /// Records a hardware `SchedulerBinding` [FrameTiming] sample into the
  /// zero-allocation ring buffer.
  void recordPlatformFrameTiming({
    required int buildMicros,
    required int rasterMicros,
    required int totalSpanMicros,
    double targetBudgetMs = 16.67,
  }) {
    _lastBuildMicros = math.max(0, buildMicros);
    _lastRasterMicros = math.max(0, rasterMicros);
    _lastTotalSpanMicros = math.max(0, totalSpanMicros);

    final bMs = _lastBuildMicros / 1000.0;
    final rMs = _lastRasterMicros / 1000.0;
    final sMs = _lastTotalSpanMicros / 1000.0;

    _buildRingMs[_platformCursor] = bMs;
    _rasterRingMs[_platformCursor] = rMs;
    _spanRingMs[_platformCursor] = sMs;
    _platformCursor = (_platformCursor + 1) % _platformRingCapacity;
    if (_platformFilled == 0) {
      _smoothedBuildMs = bMs;
      _smoothedRasterMs = rMs;
      _smoothedTotalSpanMs = sMs;
    } else {
      _smoothedBuildMs = _smoothedBuildMs * 0.85 + bMs * 0.15;
      _smoothedRasterMs = _smoothedRasterMs * 0.85 + rMs * 0.15;
      _smoothedTotalSpanMs = _smoothedTotalSpanMs * 0.85 + sMs * 0.15;
    }
    if (_platformFilled < _platformRingCapacity) {
      _platformFilled++;
    }
    if (targetBudgetMs > 0.0 && sMs > targetBudgetMs * 1.5) {
      _jankFrameCount++;
    }
  }

  /// Resets in-flight counters before recording a new render frame.
  void beginRenderFrame() {
    _drawCalls = 0;
    _atlasCalls = 0;
    _verticesCalls = 0;
    _saveLayerCalls = 0;
    _pictureCalls = 0;
    _clipCalls = 0;
    _offscreenRasterizations = 0;
  }

  /// Commits in-flight counters at the end of a render frame.
  void endRenderFrame({int? renderMicros}) {
    _lastDrawCalls = _drawCalls;
    _lastAtlasCalls = _atlasCalls;
    _lastVerticesCalls = _verticesCalls;
    _lastSaveLayerCalls = _saveLayerCalls;
    _lastPictureCalls = _pictureCalls;
    _lastClipCalls = _clipCalls;
    _lastOffscreenRasterizations = _offscreenRasterizations;
    if (renderMicros != null) {
      _renderMicros = renderMicros;
    }
  }

  /// Records the duration (in microseconds) of an `update` pass.
  @internal
  // ignore: use_setters_to_change_properties
  void recordUpdateMicros(int micros) {
    _updateMicros = micros;
  }

  /// Records an offscreen `Picture.toImageSync` rasterization pass.
  @internal
  void recordOffscreenRasterization() {
    _offscreenRasterizations++;
  }

  /// Clears all current and committed telemetry counters.
  void reset() {
    beginRenderFrame();
    endRenderFrame(renderMicros: 0);
    _updateMicros = 0;
    _platformCursor = 0;
    _platformFilled = 0;
    _lastBuildMicros = 0;
    _lastRasterMicros = 0;
    _lastTotalSpanMicros = 0;
    _smoothedBuildMs = 0.0;
    _smoothedRasterMs = 0.0;
    _smoothedTotalSpanMs = 0.0;
    _jankFrameCount = 0;
  }
}

/// Zero-allocation [Canvas] wrapper that forwards every call to a bound target
/// [Canvas] while incrementing counters on a [RenderFrameTelemetry] sink.
class TelemetryCanvas() implements Canvas {
  static final List<RenderFrameTelemetry> _activeStack = [];

  /// Currently active [RenderFrameTelemetry] during an instrumented render
  /// pass, or `null` when telemetry collection is inactive.
  @internal
  static RenderFrameTelemetry? get activeTelemetry =>
      _activeStack.isEmpty ? null : _activeStack.last;

  /// Pushes [telemetry] onto the active render stack so nested offscreen
  /// `PostProcess` passes automatically aggregate into the same frame summary.
  @internal
  static void pushActiveTelemetry(RenderFrameTelemetry telemetry) {
    _activeStack.add(telemetry);
  }

  /// Pops the most recently pushed [RenderFrameTelemetry].
  @internal
  static void popActiveTelemetry() {
    _activeStack.removeLast();
  }

  /// Wraps an offscreen [inner] canvas (e.g. inside `PostProcess`) when frame
  /// telemetry is active, or returns [inner] untouched with zero allocation
  /// when inactive.
  @internal
  static Canvas wrapOffscreenIfActive(Canvas inner) {
    final active = activeTelemetry;
    if (active == null || inner is TelemetryCanvas) {
      return inner;
    }
    active.recordOffscreenRasterization();
    return TelemetryCanvas()..bind(inner, active);
  }

  Canvas? _inner;
  RenderFrameTelemetry? _telemetry;

  /// Rebinds this reusable wrapper to [canvas] and [telemetry] without
  /// allocating a new wrapper object.
  void bind(Canvas canvas, RenderFrameTelemetry telemetry) {
    _inner = canvas;
    _telemetry = telemetry;
  }

  /// Releases the bound [Canvas] reference after a render pass completes.
  void unbind() {
    _inner = null;
    _telemetry = null;
  }

  @override
  void save() => _inner!.save();

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    _telemetry!._saveLayerCalls++;
    _inner!.saveLayer(bounds, paint);
  }

  @override
  void restore() => _inner!.restore();

  @override
  void restoreToCount(int count) => _inner!.restoreToCount(count);

  @override
  int getSaveCount() => _inner!.getSaveCount();

  @override
  void translate(double dx, double dy) => _inner!.translate(dx, dy);

  @override
  void scale(double sx, [double? sy]) => _inner!.scale(sx, sy);

  @override
  void rotate(double radians) => _inner!.rotate(radians);

  @override
  void skew(double sx, double sy) => _inner!.skew(sx, sy);

  @override
  void transform(Float64List matrix4) => _inner!.transform(matrix4);

  @override
  Float64List getTransform() => _inner!.getTransform();

  @override
  void clipRect(
    Rect rect, {
    ClipOp clipOp = ClipOp.intersect,
    bool doAntiAlias = true,
  }) {
    _telemetry!._clipCalls++;
    _inner!.clipRect(rect, clipOp: clipOp, doAntiAlias: doAntiAlias);
  }

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) {
    _telemetry!._clipCalls++;
    _inner!.clipRRect(rrect, doAntiAlias: doAntiAlias);
  }

  @override
  void clipRSuperellipse(
    RSuperellipse shape, {
    bool doAntiAlias = true,
  }) {
    _telemetry!._clipCalls++;
    _inner!.clipRSuperellipse(shape, doAntiAlias: doAntiAlias);
  }

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    _telemetry!._clipCalls++;
    _inner!.clipPath(path, doAntiAlias: doAntiAlias);
  }

  @override
  Rect getLocalClipBounds() => _inner!.getLocalClipBounds();

  @override
  Rect getDestinationClipBounds() => _inner!.getDestinationClipBounds();

  @override
  void drawColor(Color color, BlendMode blendMode) {
    _telemetry!._drawCalls++;
    _inner!.drawColor(color, blendMode);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawLine(p1, p2, paint);
  }

  @override
  void drawPaint(Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawPaint(paint);
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawRect(rect, paint);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawRRect(rrect, paint);
  }

  @override
  void drawDRRect(RRect outer, RRect inner, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawDRRect(outer, inner, paint);
  }

  @override
  void drawRSuperellipse(RSuperellipse shape, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawRSuperellipse(shape, paint);
  }

  @override
  void drawOval(Rect rect, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawOval(rect, paint);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawCircle(c, radius, paint);
  }

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    _telemetry!._drawCalls++;
    _inner!.drawArc(rect, startAngle, sweepAngle, useCenter, paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawPath(path, paint);
  }

  @override
  void drawImage(Image image, Offset offset, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawImage(image, offset, paint);
  }

  @override
  void drawImageRect(Image image, Rect src, Rect dst, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawImageRect(image, src, dst, paint);
  }

  @override
  void drawImageNine(Image image, Rect center, Rect dst, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawImageNine(image, center, dst, paint);
  }

  @override
  void drawPicture(Picture picture) {
    final t = _telemetry!;
    t._drawCalls++;
    t._pictureCalls++;
    _inner!.drawPicture(picture);
  }

  @override
  void drawParagraph(Paragraph paragraph, Offset offset) {
    _telemetry!._drawCalls++;
    _inner!.drawParagraph(paragraph, offset);
  }

  @override
  void drawPoints(PointMode pointMode, List<Offset> points, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawPoints(pointMode, points, paint);
  }

  @override
  void drawRawPoints(PointMode pointMode, Float32List points, Paint paint) {
    _telemetry!._drawCalls++;
    _inner!.drawRawPoints(pointMode, points, paint);
  }

  @override
  void drawVertices(Vertices vertices, BlendMode blendMode, Paint paint) {
    final t = _telemetry!;
    t._drawCalls++;
    t._verticesCalls++;
    _inner!.drawVertices(vertices, blendMode, paint);
  }

  @override
  void drawAtlas(
    Image atlas,
    List<RSTransform> transforms,
    List<Rect> rects,
    List<Color>? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    final t = _telemetry!;
    t._drawCalls++;
    t._atlasCalls++;
    _inner!.drawAtlas(
      atlas,
      transforms,
      rects,
      colors,
      blendMode,
      cullRect,
      paint,
    );
  }

  @override
  void drawRawAtlas(
    Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    final t = _telemetry!;
    t._drawCalls++;
    t._atlasCalls++;
    _inner!.drawRawAtlas(
      atlas,
      rstTransforms,
      rects,
      colors,
      blendMode,
      cullRect,
      paint,
    );
  }

  @override
  void drawShadow(
    Path path,
    Color color,
    double elevation,
    bool transparentOccluder,
  ) {
    _telemetry!._drawCalls++;
    _inner!.drawShadow(path, color, elevation, transparentOccluder);
  }
}
