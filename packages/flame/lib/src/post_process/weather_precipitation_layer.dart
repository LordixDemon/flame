import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/game/flame_game.dart';
import 'package:flame/src/game/game.dart';
import 'package:flutter/painting.dart';

/// Weather preset kind for [WeatherPrecipitationLayer].
enum WeatherKind() {
  clear,
  rain,
  snow,
  embers,
  hail,
  ash,
}

/// World-anchored precipitation renderer (`rain`, `snow`, `embers`, `hail`,
/// `ash`) with multi-layer depth parallax, dynamic wind gusts, and
/// deterministic ground/water splash impact callbacks.
///
/// The drops live in world space. Each one is moved every [update] by the
/// current wind and fall speed, so changing [windVelocityX], [fallSpeedY],
/// [gustStrength] or [kind] at runtime bends its path instead of making it
/// jump. The `particleCount` drops fill one tile of the size [wrapPeriod]
/// (by default the size of [fallbackBounds]), and that tile repeats endlessly
/// across the world. [render] draws the copies of the drops that lie inside
/// the rectangle the active camera sees:
///
/// - Panning, or teleporting the camera `+50,000px`, never leaves empty sky.
/// - Zooming, resizing the viewport, rotating or shaking the camera only
///   changes how much of the pattern is visible; no drop moves because the
///   view changed size. A view of the size of the tile shows `particleCount`
///   drops, a larger view more of them, a closer view fewer and larger ones.
/// - Several cameras can render the same layer; each sees the same drops at
///   the same places.
///
/// Nothing is allocated per drop. The typed-data view handed to the canvas
/// is reused from frame to frame and only re-created when the number of
/// drawn drops changes.
class WeatherPrecipitationLayer({
  this.kind = WeatherKind.rain,
  int particleCount = 128,
  this.intensity = 1.0,
  this.windVelocityX = -65.0,
  this.fallSpeedY = 460.0,
  int depthLayers = 3,
  this.gustStrength = 0.0,
  this.gustFrequency = 1.1,
  this.splashRate = 28.0,
  this.onDropImpact,
  this.fallbackBounds = const Rect.fromLTWH(0, 0, 800, 600),
  this.wrapPeriod,
  super.priority = 9000,
  super.cameraMask,
  super.key,
}) extends Component with HasVisibility {
  this {
    _depthLayerCount = depthLayers.clamp(1, 3);
    final n = math.max(1, particleCount);
    _posX = Float64List(n);
    _posY = Float64List(n);
    _speedScale = Float32List(n);
    _phase = Float32List(n);
    _layerBand = Uint8List(n);
    _linePoints = Float32List(n * 4);
    _periodW = _targetPeriodWidth;
    _periodH = _targetPeriodHeight;

    for (var i = 0; i < n; i++) {
      // Depth parallax bands (`0` = far, `1` = mid, `2` = near foreground).
      final band = i % _depthLayerCount;
      _layerBand[i] = band;
      // A two-dimensional low-discrepancy sequence spreads the drops evenly
      // over the tile from the first frame on.
      _posX[i] = ((0.5 + i * 0.7548776662466927) % 1.0) * _periodW;
      _posY[i] = ((0.5 + i * 0.5698402909980532) % 1.0) * _periodH;
      final parallaxMul = _depthLayerCount == 1
          ? 1.0
          : (0.66 + (band / (_depthLayerCount - 1)) * 0.68);
      _speedScale[i] = (0.76 + (i % 7) * 0.06) * parallaxMul;
      _phase[i] = i * 0.91;
    }
  }

  /// A view never draws more than this many tiles side by side; wider views
  /// repeat a correspondingly larger, sparser tile.
  static const int _maxTilesPerAxis = 8;

  WeatherKind kind;
  double intensity;
  double windVelocityX;
  double fallSpeedY;

  /// Amplitude of coherent storm wind gusts added to [windVelocityX].
  double gustStrength;

  /// Oscillation rate in rad/s for storm wind gusts.
  double gustFrequency;

  /// Impacts per second (at `intensity == 1.0`) that land on one tile of the
  /// size [wrapPeriod] while `kind` is `rain` or `hail`.
  ///
  /// [onDropImpact] receives the ones inside the camera-visible rectangle, so
  /// a view of the size of the tile gets this many callbacks per second and a
  /// closer view proportionally fewer.
  double splashRate;

  /// Optional callback invoked at deterministic impact points inside the
  /// rectangle the camera sees: the one of the most recent [render], else the
  /// view of the game's camera, else [fallbackBounds] when there is no
  /// camera. Rainfall/hail can thus excite `WaterRipplePoolComponent` or
  /// `WaterSurface2DComponent` with zero allocations.
  void Function(double worldX, double worldY)? onDropImpact;

  /// The world rectangle used as the view when the layer is rendered without
  /// a camera, and for [onDropImpact] until a camera has rendered it. Its
  /// size is also the default [wrapPeriod].
  Rect fallbackBounds;

  /// The size of the world-space tile that holds the `particleCount` drops
  /// and repeats in both directions, or `null` to use the size of
  /// [fallbackBounds].
  ///
  /// It sets the density of the precipitation: a camera that sees exactly
  /// one tile sees `particleCount` drops. It does not depend on the camera,
  /// which is what keeps the drops in place while the view changes size.
  /// Changing it rescales the pattern.
  Size? wrapPeriod;

  late final int _depthLayerCount;
  late final Float64List _posX;
  late final Float64List _posY;
  late final Float32List _speedScale;
  late final Float32List _phase;
  late final Uint8List _layerBand;
  late Float32List _linePoints;
  final List<Float32List?> _bandViews = List<Float32List?>.filled(3, null);
  final List<Color?> _bandColors = List<Color?>.filled(3, null);
  final Int32List _bandColorValues = Int32List(3);
  late double _periodW;
  late double _periodH;

  double _elapsed = 0.0;
  double _splashDebt = 0.0;
  int _splashSeq = 0;
  int _lastActiveDropCount = 0;
  Rect? _lastCameraView;

  final Paint _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  /// Number of precipitation drops drawn in the last [render] pass, counting
  /// every visible copy of a drop.
  int get lastActiveDropCount => _lastActiveDropCount;

  /// Current effective horizontal wind velocity including active gusts.
  double get currentWindVelocityX =>
      windVelocityX +
      (gustStrength == 0.0
          ? 0.0
          : math.sin(_elapsed * gustFrequency) * gustStrength);

  /// Depth parallax band (`0 .. depthLayers - 1`) assigned to drop [index].
  int depthBandOf(int index) => _layerBand[index];

  /// Speed multiplier assigned to drop [index] (monotonically larger for nearer
  /// parallax bands at matching `(index % 7)`).
  double speedScaleOf(int index) => _speedScale[index];

  double get _targetPeriodWidth =>
      math.max(1.0, wrapPeriod?.width ?? fallbackBounds.width);

  double get _targetPeriodHeight =>
      math.max(1.0, wrapPeriod?.height ?? fallbackBounds.height);

  /// Rescales the drop pattern when the wrap period was changed.
  void _syncPeriod() {
    final pw = _targetPeriodWidth;
    final ph = _targetPeriodHeight;
    if (pw == _periodW && ph == _periodH) {
      return;
    }
    final sx = pw / _periodW;
    final sy = ph / _periodH;
    for (var i = 0; i < _posX.length; i++) {
      _posX[i] *= sx;
      _posY[i] *= sy;
    }
    _periodW = pw;
    _periodH = ph;
  }

  /// Horizontal sway of drop [index], which is added on top of its position.
  double _swayOf(int index) => switch (kind) {
    WeatherKind.snow => math.sin(_elapsed * 2.4 + _phase[index]) * 18.0,
    WeatherKind.embers => math.sin(_elapsed * 3.1 + _phase[index]) * 24.0,
    WeatherKind.ash => math.sin(_elapsed * 1.8 + _phase[index]) * 30.0,
    _ => 0.0,
  };

  /// Samples the world position of the copy of drop [index] that lies at or
  /// right of and below the top-left corner of [bounds], which is inside
  /// [bounds] whenever [bounds] is at least as large as the wrap period
  /// (exposed for deterministic verification).
  ///
  /// The result does not depend on the size of [bounds].
  Offset sampleDropPosition(int index, Rect bounds) {
    _syncPeriod();
    return Offset(
      bounds.left +
          _posMod(_posX[index] + _swayOf(index) - bounds.left, _periodW),
      bounds.top + _posMod(_posY[index] - bounds.top, _periodH),
    );
  }

  static double _posMod(double value, double mod) {
    final r = value % mod;
    return r < 0.0 ? r + mod : r;
  }

  @override
  void update(double dt) {
    super.update(dt);
    final clampedInt = intensity.clamp(0.0, 1.0);
    if (kind == WeatherKind.clear || clampedInt <= 1e-3 || dt <= 0.0) {
      return;
    }
    _syncPeriod();
    _elapsed += dt;

    // Every drop advances by the velocity of this moment, so a change of
    // wind, fall speed or kind only affects where it goes from here.
    final fallVelocity = switch (kind) {
      WeatherKind.embers => -fallSpeedY * 0.35,
      WeatherKind.ash => fallSpeedY * 0.22,
      WeatherKind.hail => fallSpeedY * 1.28,
      _ => fallSpeedY,
    };
    final vx = currentWindVelocityX * dt;
    final vy = fallVelocity * dt;
    final pw = _periodW;
    final ph = _periodH;
    for (var i = 0; i < _posX.length; i++) {
      final sp = _speedScale[i];
      _posX[i] = _posMod(_posX[i] + vx * sp, pw);
      _posY[i] = _posMod(_posY[i] + vy * sp, ph);
    }

    final impactCb = onDropImpact;
    if (impactCb != null &&
        splashRate > 0.0 &&
        (kind == WeatherKind.rain || kind == WeatherKind.hail)) {
      final bounds = _impactBounds();
      // The rate is per tile; the visible rectangle gets its share of it.
      final share = math.min(
        (bounds.width * bounds.height) / (pw * ph),
        (_maxTilesPerAxis * _maxTilesPerAxis).toDouble(),
      );
      _splashDebt += splashRate * clampedInt * share * dt;
      final count = _splashDebt.floor();
      if (count > 0) {
        _splashDebt -= count;
        for (var k = 0; k < count; k++) {
          _splashSeq = (_splashSeq + 1) & 0x7fffffff;
          final u = (_splashSeq * 0.61803398875) % 1.0;
          final v = (_splashSeq * 0.32471795724 + 0.19) % 1.0;
          impactCb(
            bounds.left + u * bounds.width,
            bounds.top + (0.35 + 0.65 * v) * bounds.height,
          );
        }
      }
    }
    Game.notifyVisualMutation();
  }

  /// The world rectangle the impacts land in: what a camera showed in the
  /// last [render], else what the game's camera sees now, else
  /// [fallbackBounds].
  Rect _impactBounds() {
    final seen = _lastCameraView;
    if (seen != null) {
      return seen;
    }
    final game = findGame();
    if (game is FlameGame) {
      final camera = game.camera;
      if (camera.isMounted && camera.parent != null) {
        final view = camera.visibleWorldRect;
        if (view.width > 0.0 &&
            view.height > 0.0 &&
            view.width.isFinite &&
            view.height.isFinite) {
          return view;
        }
      }
    }
    return fallbackBounds;
  }

  /// The first [length] floats of [_linePoints] as a list, without allocating
  /// while [length] stays the same from frame to frame.
  Float32List _lineSlice(int band, int length) {
    if (length == _linePoints.length) {
      return _linePoints;
    }
    final cached = _bandViews[band];
    if (cached != null && cached.length == length) {
      return cached;
    }
    return _bandViews[band] = Float32List.sublistView(_linePoints, 0, length);
  }

  /// The color `0xAARRGGBB` for [band], reusing last frame's object while the
  /// value is unchanged.
  Color _bandColor(int band, int alpha, int rgb) {
    final value = (alpha << 24) | rgb;
    final cached = _bandColors[band];
    if (cached != null && _bandColorValues[band] == value) {
      return cached;
    }
    _bandColorValues[band] = value;
    return _bandColors[band] = Color(value);
  }

  void _growLinePoints() {
    final grown = Float32List(_linePoints.length * 2)
      ..setRange(0, _linePoints.length, _linePoints);
    _linePoints = grown;
    // The cached views look at the old storage.
    _bandViews.fillRange(0, _bandViews.length, null);
  }

  @override
  void render(Canvas canvas) {
    _lastActiveDropCount = 0;
    final camera = CameraComponent.currentCamera;
    final Rect bounds;
    if (camera != null) {
      bounds = camera.visibleWorldRect;
      _lastCameraView = bounds;
    } else {
      bounds = fallbackBounds;
      _lastCameraView = null;
    }
    final clampedInt = intensity.clamp(0.0, 1.0);
    if (kind == WeatherKind.clear || clampedInt <= 1e-3) {
      return;
    }

    final total = (_posX.length * clampedInt).round().clamp(0, _posX.length);
    if (total == 0 ||
        !(bounds.width > 0.0 && bounds.height > 0.0) ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite) {
      return;
    }
    _syncPeriod();

    // The pattern repeats every period. A view wider than a few periods is
    // covered with a tile several periods wide instead, over which the drops
    // are spread by index, so the number of copies stays bounded.
    final pw = _periodW;
    final ph = _periodH;
    var tilesX = 1;
    while (bounds.width > pw * tilesX * _maxTilesPerAxis) {
      tilesX *= 2;
    }
    var tilesY = 1;
    while (bounds.height > ph * tilesY * _maxTilesPerAxis) {
      tilesY *= 2;
    }
    final stepX = pw * tilesX;
    final stepY = ph * tilesY;
    final left = bounds.left;
    final top = bounds.top;
    final right = bounds.right;
    final bottom = bounds.bottom;

    final effWindX = currentWindVelocityX;
    var renderedTotal = 0;

    for (var band = 0; band < _depthLayerCount; band++) {
      final bandFrac = _depthLayerCount == 1
          ? 1.0
          : band / (_depthLayerCount - 1);
      final bandAlphaScale = 0.52 + 0.48 * bandFrac;
      final bandWidthScale = 0.72 + 0.52 * bandFrac;
      final bandStreakScale = 0.75 + 0.50 * bandFrac;

      final baseAlpha =
          (clampedInt * bandAlphaScale * (kind == WeatherKind.rain ? 165 : 215))
              .round()
              .clamp(0, 255);
      if (baseAlpha <= 2) {
        continue;
      }

      switch (kind) {
        case WeatherKind.clear:
          return;
        case WeatherKind.rain:
          _paint
            ..color = _bandColor(band, baseAlpha, 0xB9DAFF)
            ..strokeWidth = 1.35 * bandWidthScale;
        case WeatherKind.hail:
          _paint
            ..color = _bandColor(band, baseAlpha, 0xE4F5FF)
            ..strokeWidth = 2.4 * bandWidthScale;
        case WeatherKind.snow:
          _paint
            ..color = _bandColor(band, baseAlpha, 0xF5FAFF)
            ..strokeWidth = 3.2 * bandWidthScale;
        case WeatherKind.embers:
          _paint
            ..color = _bandColor(band, baseAlpha, 0xFF9442)
            ..strokeWidth = 2.6 * bandWidthScale;
        case WeatherKind.ash:
          _paint
            ..color = _bandColor(band, baseAlpha, 0xA8A6AE)
            ..strokeWidth = 2.5 * bandWidthScale;
      }

      final streakDx = switch (kind) {
        WeatherKind.rain => effWindX * 0.032 * bandStreakScale,
        WeatherKind.hail => effWindX * 0.016 * bandStreakScale,
        _ => 0.0,
      };
      final streakDy = switch (kind) {
        WeatherKind.rain => fallSpeedY * 0.032 * bandStreakScale,
        WeatherKind.hail => fallSpeedY * 0.020 * bandStreakScale,
        WeatherKind.embers => -3.0 * bandStreakScale,
        WeatherKind.ash => 1.2 * bandStreakScale,
        _ => 0.5,
      };

      var cursor = 0;
      for (var i = 0; i < total; i++) {
        if (_layerBand[i] != band) {
          continue;
        }
        final x0 = _posX[i] + _swayOf(i) + (i % tilesX) * pw;
        final y0 = _posY[i] + ((i ~/ tilesX) % tilesY) * ph;
        final firstY = top + _posMod(y0 - top, stepY);
        for (var x = left + _posMod(x0 - left, stepX); x < right; x += stepX) {
          for (var y = firstY; y < bottom; y += stepY) {
            if (cursor + 4 > _linePoints.length) {
              _growLinePoints();
            }
            _linePoints[cursor++] = x;
            _linePoints[cursor++] = y;
            _linePoints[cursor++] = x + streakDx;
            _linePoints[cursor++] = y + streakDy;
            renderedTotal++;
          }
        }
      }

      if (cursor > 0) {
        canvas.drawRawPoints(
          ui.PointMode.lines,
          _lineSlice(band, cursor),
          _paint,
        );
      }
    }
    _lastActiveDropCount = renderedTotal;
  }
}
