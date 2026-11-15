import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/cache/memory_cache.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/game/game.dart';

/// Zero-allocation Struct-of-Arrays pool of expanding concentric capillary
/// water ripples for top-down, HD-2D, and `2:1` isometric water or wet puddles.
///
/// Renders all active ripples in **1 single GPU `Canvas.drawVertices` call**
/// using a cached procedural double-ring texture so non-uniform isometric
/// [aspectRatio] (`0.5` for `2:1` dimetric projection) works without per-ripple
/// canvas state saves.
class WaterRipplePoolComponent({
  this.capacity = 128,
  this.aspectRatio = 0.55,
  super.priority,
  super.cameraMask,
  super.key,
}) extends Component with HasVisibility {
  this
    : assert(capacity > 0, 'capacity must be positive'),
      assert(aspectRatio > 0, 'aspectRatio must be positive') {
    _posX = Float32List(capacity);
    _posY = Float32List(capacity);
    _age = Float32List(capacity);
    _invLife = Float32List(capacity);
    _startRadius = Float32List(capacity);
    _maxRadius = Float32List(capacity);
    _argb = Int32List(capacity);
    _quadPositions = Float32List(capacity * 8);
    _quadUvs = Float32List(capacity * 8);
    _quadColors = Int32List(capacity * 4);
    _quadIndices = Uint16List(capacity * 6);
    for (var i = 0; i < capacity; i++) {
      final v = i * 4;
      final k = i * 6;
      _quadIndices[k] = v;
      _quadIndices[k + 1] = v + 1;
      _quadIndices[k + 2] = v + 2;
      _quadIndices[k + 3] = v;
      _quadIndices[k + 4] = v + 2;
      _quadIndices[k + 5] = v + 3;

      final u = i * 8;
      _quadUvs[u] = 0.0;
      _quadUvs[u + 1] = 0.0;
      _quadUvs[u + 2] = _texSize * 1.0;
      _quadUvs[u + 3] = 0.0;
      _quadUvs[u + 4] = _texSize * 1.0;
      _quadUvs[u + 5] = _texSize * 1.0;
      _quadUvs[u + 6] = 0.0;
      _quadUvs[u + 7] = _texSize * 1.0;
    }
  }

  /// Maximum number of simultaneous ripples.
  final int capacity;

  /// Vertical-to-horizontal ellipse ratio (`1.0` = top-down circle, `0.5` =
  /// `2:1` isometric ellipse).
  double aspectRatio;

  static const int _texSize = 64;
  static final MemoryCache<int, ui.Image> _ringTextureCache =
      MemoryCache<int, ui.Image>(
        cacheSize: 4,
        onEvict: (_, img) => img.dispose(),
      );

  static ui.Image _obtainRingTexture() {
    final cached = _ringTextureCache.getValue(0);
    if (cached != null) {
      return cached;
    }
    const r = _texSize * 0.5;
    const center = ui.Offset(r, r);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final p = ui.Paint()
      ..shader = ui.Gradient.radial(
        center,
        r,
        const <ui.Color>[
          ui.Color(0x00FFFFFF),
          ui.Color(0x55FFFFFF),
          ui.Color(0x00FFFFFF),
          ui.Color(0xEEFFFFFF),
          ui.Color(0x00FFFFFF),
        ],
        const <double>[0.0, 0.44, 0.62, 0.86, 1.0],
      );
    canvas.drawCircle(center, r, p);
    final picture = recorder.endRecording();
    final img = picture.toImageSync(_texSize, _texSize);
    picture.dispose();
    _ringTextureCache.setValue(0, img);
    return img;
  }

  late final Float32List _posX;
  late final Float32List _posY;
  late final Float32List _age;
  late final Float32List _invLife;
  late final Float32List _startRadius;
  late final Float32List _maxRadius;
  late final Int32List _argb;
  late final Float32List _quadPositions;
  late final Float32List _quadUvs;
  late final Int32List _quadColors;
  late final Uint16List _quadIndices;

  final ui.Paint _paint = ui.Paint()..blendMode = ui.BlendMode.plus;
  ui.Image? _boundTex;
  ui.ImageShader? _shader;

  int _activeCount = 0;
  int _overwriteCursor = 0;
  int _lastDrawCalls = 0;

  /// Number of currently active ripples.
  int get activeCount => _activeCount;

  /// Number of GPU draw calls issued during the last [render] (`0` or `1`).
  int get lastDrawCalls => _lastDrawCalls;

  /// Spawns an expanding concentric ripple at `(x, y)`.
  void spawnRipple(
    double x,
    double y, {
    double startRadius = 3.0,
    double maxRadius = 28.0,
    double lifespan = 0.85,
    ui.Color color = const ui.Color(0xBBD8F3FF),
  }) {
    final int slot;
    if (_activeCount < capacity) {
      slot = _activeCount++;
    } else {
      slot = _overwriteCursor;
      _overwriteCursor = (_overwriteCursor + 1) % capacity;
    }
    _posX[slot] = x;
    _posY[slot] = y;
    _age[slot] = 0.0;
    _invLife[slot] = 1.0 / math.max(0.08, lifespan);
    _startRadius[slot] = startRadius;
    _maxRadius[slot] = math.max(startRadius + 1.0, maxRadius);
    _argb[slot] = color.toARGB32();
    Game.notifyVisualMutation();
  }

  /// Clears all active ripples.
  void clear() {
    if (_activeCount > 0) {
      _activeCount = 0;
      _overwriteCursor = 0;
      Game.notifyVisualMutation();
    }
  }

  @override
  void onRemove() {
    _shader?.dispose();
    _shader = null;
    _boundTex = null;
    super.onRemove();
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_activeCount == 0 || dt <= 0.0) {
      return;
    }
    Game.notifyVisualMutation();
    var i = 0;
    while (i < _activeCount) {
      final nextAge = _age[i] + dt;
      if (nextAge * _invLife[i] >= 1.0) {
        final last = --_activeCount;
        if (i != last) {
          _posX[i] = _posX[last];
          _posY[i] = _posY[last];
          _age[i] = _age[last];
          _invLife[i] = _invLife[last];
          _startRadius[i] = _startRadius[last];
          _maxRadius[i] = _maxRadius[last];
          _argb[i] = _argb[last];
        }
        continue;
      }
      _age[i] = nextAge;
      i++;
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (_activeCount == 0) {
      _lastDrawCalls = 0;
      return;
    }
    final tex = _obtainRingTexture();
    if (!identical(_boundTex, tex) || _shader == null) {
      _shader?.dispose();
      _boundTex = tex;
      _shader = ui.ImageShader(
        tex,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        Float64List.fromList(const <double>[
          1, 0, 0, 0, //
          0, 1, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ]),
      );
      _paint.shader = _shader;
    }

    var quadCount = 0;
    for (var i = 0; i < _activeCount; i++) {
      final p = (_age[i] * _invLife[i]).clamp(0.0, 1.0);
      // Fast ease-out expansion: 1 - (1 - p)^2
      final ease = 1.0 - (1.0 - p) * (1.0 - p);
      final rx = _startRadius[i] + (_maxRadius[i] - _startRadius[i]) * ease;
      final ry = rx * aspectRatio;
      final fade = (1.0 - p) * (1.0 - p * 0.45);
      final raw = _argb[i];
      final baseA = (raw >>> 24) & 0xFF;
      final a = (baseA * fade).round().clamp(0, 255);
      if (a <= 2) {
        continue;
      }
      final col = (a << 24) | (raw & 0x00FFFFFF);
      final cx = _posX[i];
      final cy = _posY[i];

      final posBase = quadCount * 8;
      _quadPositions[posBase] = cx - rx;
      _quadPositions[posBase + 1] = cy - ry;
      _quadPositions[posBase + 2] = cx + rx;
      _quadPositions[posBase + 3] = cy - ry;
      _quadPositions[posBase + 4] = cx + rx;
      _quadPositions[posBase + 5] = cy + ry;
      _quadPositions[posBase + 6] = cx - rx;
      _quadPositions[posBase + 7] = cy + ry;

      final colBase = quadCount * 4;
      _quadColors[colBase] = col;
      _quadColors[colBase + 1] = col;
      _quadColors[colBase + 2] = col;
      _quadColors[colBase + 3] = col;
      quadCount++;
    }

    if (quadCount == 0) {
      _lastDrawCalls = 0;
      return;
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_quadPositions, 0, quadCount * 8),
      textureCoordinates: Float32List.sublistView(_quadUvs, 0, quadCount * 8),
      colors: Int32List.sublistView(_quadColors, 0, quadCount * 4),
      indices: Uint16List.sublistView(_quadIndices, 0, quadCount * 6),
    );
    canvas.drawVertices(vertices, ui.BlendMode.modulate, _paint);
    vertices.dispose();
    _lastDrawCalls = 1;
  }
}
