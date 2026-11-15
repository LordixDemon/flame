import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/rendering/light_2d_layer.dart';

/// Sampled or procedural 3D surface normal `(nx, ny, nz)` (`+X` right, `+Y`
/// down in 2D canvas space, `+Z` out of the screen toward the viewer).
class const SurfaceNormal2D(this.nx, this.ny, this.nz) {
  static const SurfaceNormal2D flat = SurfaceNormal2D(0.0, 0.0, 1.0);

  final double nx;
  final double ny;
  final double nz;

  /// Decodes a tangent-space RGBA normal map pixel (`R -> X`, `G -> Y`,
  /// `B -> Z`, where `128, 128, 255` is flat `(0, 0, 1)`).
  factory SurfaceNormal2D.fromRgbBytes(
    int r,
    int g,
    int b, {
    bool flipGreenY = false,
  }) {
    var x = (r / 255.0) * 2.0 - 1.0;
    var y = (g / 255.0) * 2.0 - 1.0;
    if (flipGreenY) {
      y = -y;
    }
    var z = (b / 255.0) * 2.0 - 1.0;
    final len = math.sqrt(x * x + y * y + z * z);
    if (len > 1e-6) {
      x /= len;
      y /= len;
      z /= len;
    } else {
      x = 0.0;
      y = 0.0;
      z = 1.0;
    }
    return SurfaceNormal2D(x, y, z);
  }
}

/// Zero-allocation 2D normal-lit sprite batcher computing directional / point
/// `dot(N, L)` bevel & surface relief lighting across `PointLight2D` sources
/// and flushing into `1` `Canvas.drawVertices` GPU call.
class NormalMappedSpriteBatch({
  required this.diffuseAtlas,
  this.ambientColor = const ui.Color(0xFF404860),
  this.defaultLightHeightZ = 48.0,
  int initialSpriteCapacity = 64,
}) {
  final ui.Image diffuseAtlas;
  ui.Color ambientColor;
  double defaultLightHeightZ;

  late final ui.ImageShader _shader = ui.ImageShader(
    diffuseAtlas,
    ui.TileMode.clamp,
    ui.TileMode.clamp,
    Float64List.fromList(const <double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]),
  );

  final ui.Paint _paint = ui.Paint()..filterQuality = ui.FilterQuality.low;

  Float32List _positions = Float32List(initialSpriteCapacity * 8);
  Float32List _uvs = Float32List(initialSpriteCapacity * 8);
  Int32List _colors = Int32List(initialSpriteCapacity * 4);
  Uint16List _indices = _buildQuadIndices(initialSpriteCapacity);

  int _spriteCount = 0;
  int _lastDrawCalls = 0;

  int get spriteCount => _spriteCount;
  int get lastDrawCalls => _lastDrawCalls;

  static Uint16List _buildQuadIndices(int quadCap) {
    final safeCap = math.min(quadCap, 16383);
    final idx = Uint16List(safeCap * 6);
    for (var i = 0; i < safeCap; i++) {
      final v = i * 4;
      final o = i * 6;
      idx[o] = v;
      idx[o + 1] = v + 1;
      idx[o + 2] = v + 2;
      idx[o + 3] = v;
      idx[o + 4] = v + 2;
      idx[o + 5] = v + 3;
    }
    return idx;
  }

  void _ensureCapacity(int neededSprites) {
    final curCap = _colors.length ~/ 4;
    if (neededSprites <= curCap) {
      return;
    }
    var nextCap = math.max(16, curCap * 2);
    while (nextCap < neededSprites) {
      nextCap *= 2;
    }
    nextCap = math.min(nextCap, 16383);
    _positions = Float32List(nextCap * 8)
      ..setRange(0, _spriteCount * 8, _positions);
    _uvs = Float32List(nextCap * 8)..setRange(0, _spriteCount * 8, _uvs);
    _colors = Int32List(nextCap * 4)..setRange(0, _spriteCount * 4, _colors);
    _indices = _buildQuadIndices(nextCap);
  }

  /// Clears queued quads for a new frame.
  void clear() {
    _spriteCount = 0;
  }

  /// Evaluates exact `dot(N, L)` lighting color at 2D world point `(wx, wy)`
  /// with surface normal [normal] against [ambientColor] and [lights].
  ui.Color evaluateLitColor({
    required double wx,
    required double wy,
    required SurfaceNormal2D normal,
    required List<PointLight2D> lights,
    ui.Color baseTint = const ui.Color(0xFFFFFFFF),
    double opacity = 1.0,
  }) {
    var accR = ambientColor.r;
    var accG = ambientColor.g;
    var accB = ambientColor.b;

    for (var i = 0; i < lights.length; i++) {
      final l = lights[i];
      if (!l.enabled || l.intensity <= 0.0 || l.radius <= 0.0) {
        continue;
      }
      final dx = l.position.x - wx;
      final dy = l.position.y - wy;
      final dist2D = math.sqrt(dx * dx + dy * dy);
      if (dist2D >= l.radius) {
        continue;
      }
      final dz = defaultLightHeightZ;
      final invLen3 = 1.0 / math.sqrt(dx * dx + dy * dy + dz * dz);
      final lx = dx * invLen3;
      final ly = dy * invLen3;
      final lz = dz * invLen3;

      final ndotl = math.max(
        0.0,
        normal.nx * lx + normal.ny * ly + normal.nz * lz,
      );
      if (ndotl <= 0.0) {
        continue;
      }
      final falloff = 1.0 - (dist2D / l.radius);
      final atten = falloff * falloff * l.intensity * ndotl;
      accR += l.color.r * atten;
      accG += l.color.g * atten;
      accB += l.color.b * atten;
    }

    final r = (accR * baseTint.r * 255.0).round().clamp(0, 255);
    final g = (accG * baseTint.g * 255.0).round().clamp(0, 255);
    final b = (accB * baseTint.b * 255.0).round().clamp(0, 255);
    final a = (baseTint.a * opacity.clamp(0.0, 1.0) * 255.0).round().clamp(
      0,
      255,
    );
    return ui.Color.fromARGB(a, r, g, b);
  }

  /// Adds a sprite quad `[dstRect]` sampling `[srcRect]` with either uniform
  /// [faceNormal] or spherical/bevel [bevelCurvature] (`0.0 .. 1.0`, curving
  /// corner normals outward so torches catch crisp bright edges on stone tiles,
  /// chests, pillars, and tokens!).
  void addLitSprite({
    required ui.Rect srcRect,
    required ui.Rect dstRect,
    required List<PointLight2D> lights,
    SurfaceNormal2D faceNormal = SurfaceNormal2D.flat,
    double bevelCurvature = 0.45,
    ui.Color tint = const ui.Color(0xFFFFFFFF),
    double opacity = 1.0,
  }) {
    if (_spriteCount >= 16383 || opacity <= 0.0) {
      return;
    }
    _ensureCapacity(_spriteCount + 1);

    final slot = _spriteCount++;
    final pBase = slot * 8;
    _positions[pBase] = dstRect.left;
    _positions[pBase + 1] = dstRect.top;
    _positions[pBase + 2] = dstRect.right;
    _positions[pBase + 3] = dstRect.top;
    _positions[pBase + 4] = dstRect.right;
    _positions[pBase + 5] = dstRect.bottom;
    _positions[pBase + 6] = dstRect.left;
    _positions[pBase + 7] = dstRect.bottom;

    _uvs[pBase] = srcRect.left;
    _uvs[pBase + 1] = srcRect.top;
    _uvs[pBase + 2] = srcRect.right;
    _uvs[pBase + 3] = srcRect.top;
    _uvs[pBase + 4] = srcRect.right;
    _uvs[pBase + 5] = srcRect.bottom;
    _uvs[pBase + 6] = srcRect.left;
    _uvs[pBase + 7] = srcRect.bottom;

    final bev = bevelCurvature.clamp(0.0, 0.95);
    const cornerSigns = <(double, double)>[
      (-1.0, -1.0),
      (1.0, -1.0),
      (1.0, 1.0),
      (-1.0, 1.0),
    ];
    final cornerX = <double>[
      dstRect.left,
      dstRect.right,
      dstRect.right,
      dstRect.left,
    ];
    final cornerY = <double>[
      dstRect.top,
      dstRect.top,
      dstRect.bottom,
      dstRect.bottom,
    ];

    final cBase = slot * 4;
    for (var c = 0; c < 4; c++) {
      final (sx, sy) = cornerSigns[c];
      var nx = faceNormal.nx + sx * bev * 0.70710678;
      var ny = faceNormal.ny + sy * bev * 0.70710678;
      var nz = faceNormal.nz;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-6) {
        nx /= len;
        ny /= len;
        nz /= len;
      }
      final lit = evaluateLitColor(
        wx: cornerX[c],
        wy: cornerY[c],
        normal: SurfaceNormal2D(nx, ny, nz),
        lights: lights,
        baseTint: tint,
        opacity: opacity,
      );
      _colors[cBase + c] = lit.toARGB32();
    }
  }

  /// Flushes all queued lit quads in `1` `Canvas.drawVertices` GPU call.
  void flush(ui.Canvas canvas) {
    _lastDrawCalls = 0;
    if (_spriteCount == 0) {
      return;
    }
    _paint.shader = _shader;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _spriteCount * 8),
      textureCoordinates: Float32List.sublistView(_uvs, 0, _spriteCount * 8),
      colors: Int32List.sublistView(_colors, 0, _spriteCount * 4),
      indices: Uint16List.sublistView(_indices, 0, _spriteCount * 6),
    );
    canvas.drawVertices(vertices, ui.BlendMode.modulate, _paint);
    vertices.dispose();
    _lastDrawCalls = 1;
  }

  void dispose() {
    _shader.dispose();
  }
}

/// Animated 2D/HD-2D water surface component featuring shoreline foam,
/// horizontal wave-displaced planar reflection strips (compatible with
/// `RenderTextureComponent.texture`), and animated specular glints.
class WaterSurface2DComponent({
  this.deepColor = const ui.Color(0xFF164A7A),
  this.shallowColor = const ui.Color(0xFF2C82B5),
  this.foamColor = const ui.Color(0xD8EEF9FF),
  this.glintColor = const ui.Color(0x99FFFBE0),
  this.shoreFoamHeight = 6.0,
  this.waveSpeed = 2.2,
  this.waveAmplitudePx = 3.5,
  this.reflectionOpacity = 0.38,
  this.reflectionBands = 12,
  this.reflectionTexture,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility {
  ui.Color deepColor;
  ui.Color shallowColor;
  ui.Color foamColor;
  ui.Color glintColor;
  double shoreFoamHeight;
  double waveSpeed;
  double waveAmplitudePx;
  double reflectionOpacity;
  int reflectionBands;

  /// Optional live planar reflection image (e.g. from a
  /// `RenderTextureComponent`).
  ui.Image? reflectionTexture;

  double _elapsed = 0.0;
  final ui.Paint _fillPaint = ui.Paint();
  final ui.Paint _foamPaint = ui.Paint();
  final ui.Paint _reflPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;
  final Float32List _glintSegments = Float32List(32);

  double get elapsed => _elapsed;

  @override
  void update(double dt) {
    super.update(dt);
    if (dt > 0.0 && waveSpeed != 0.0) {
      _elapsed += dt;
      Game.notifyVisualMutation();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (size.x <= 0.0 || size.y <= 0.0) {
      return;
    }
    final rect = ui.Rect.fromLTWH(0, 0, size.x, size.y);

    // 1. Depth gradient base:
    _fillPaint.shader = ui.Gradient.linear(
      ui.Offset.zero,
      ui.Offset(0, size.y),
      <ui.Color>[shallowColor, deepColor],
    );
    canvas.drawRect(rect, _fillPaint);

    // 2. Wave-rippled planar reflection bands:
    final refl = reflectionTexture;
    if (refl != null && reflectionOpacity > 1e-3 && reflectionBands > 0) {
      final bands = reflectionBands.clamp(1, 64);
      final bandDstH = size.y / bands;
      final bandSrcH = refl.height / bands;
      _reflPaint.color = ui.Color.fromARGB(
        (reflectionOpacity.clamp(0.0, 1.0) * 255).round(),
        255,
        255,
        255,
      );
      canvas.save();
      canvas.clipRect(rect);
      for (var b = 0; b < bands; b++) {
        final waveDx =
            math.sin(_elapsed * waveSpeed + b * 0.85) * waveAmplitudePx;
        // Vertically flip reflection bands (top of water reflects bottom of
        // shore scene!):
        final srcRow = bands - 1 - b;
        final src = ui.Rect.fromLTWH(
          0,
          srcRow * bandSrcH,
          refl.width.toDouble(),
          bandSrcH,
        );
        final dst = ui.Rect.fromLTWH(
          waveDx,
          b * bandDstH,
          size.x,
          bandDstH + 0.5,
        );
        canvas.drawImageRect(refl, src, dst, _reflPaint);
      }
      canvas.restore();
    }

    // 3. Undulating shoreline foam ribbon:
    if (shoreFoamHeight > 0.0) {
      final pulse = 1.0 + 0.22 * math.sin(_elapsed * waveSpeed * 1.4);
      final fh = (shoreFoamHeight * pulse).clamp(1.0, size.y);
      _foamPaint.shader = ui.Gradient.linear(
        ui.Offset.zero,
        ui.Offset(0, fh),
        <ui.Color>[foamColor, const ui.Color(0x00FFFFFF)],
      );
      canvas.drawRect(ui.Rect.fromLTWH(0, 0, size.x, fh), _foamPaint);
    }

    // 4. Animated specular sun/moon water glints:
    _foamPaint
      ..shader = null
      ..color = glintColor
      ..strokeWidth = 1.6
      ..strokeCap = ui.StrokeCap.round;
    var cursor = 0;
    for (var i = 0; i < 8; i++) {
      final shimmer = math.sin(_elapsed * waveSpeed * 1.8 + i * 1.7);
      if (shimmer <= 0.15) {
        continue;
      }
      final gx =
          ((i * 0.37 + 0.11) % 0.86 + 0.05) * size.x +
          math.cos(_elapsed + i) * 4.0;
      final gy = ((i * 0.29 + 0.18) % 0.75 + 0.15) * size.y;
      final halfLen = (4.0 + 8.0 * shimmer).clamp(2.0, size.x * 0.25);
      _glintSegments[cursor++] = gx - halfLen;
      _glintSegments[cursor++] = gy;
      _glintSegments[cursor++] = gx + halfLen;
      _glintSegments[cursor++] = gy;
    }
    if (cursor > 0) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.sublistView(_glintSegments, 0, cursor),
        _foamPaint,
      );
    }
  }
}
