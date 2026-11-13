import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Built-in procedural MatCap material presets for [MatCapShader3D].
enum MatCapPreset3D() {
  /// High-contrast warm gold/brass reflection sphere with specular hotspot.
  metallicGold,

  /// Clean neutral studio lacquer/porcelain reflection sphere.
  glossyLacquer,
}

/// Procedural GPU `ImageShader` MatCap generator for `Canvas.drawVertices`
/// meshes using spherical normal-mapped UVs (`u = (vx * 0.48 + 0.5) * size`,
/// `v = (0.5 - vy * 0.48) * size`).
class MatCapShader3D() {
  /// Side resolution in pixels of each baked MatCap sphere texture.
  static const int resolution = 64;

  static final Float64List _identityMatrix = Float64List.fromList(const [
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
  ]);

  ui.Image? _goldImg;
  ui.Image? _lacquerImg;
  ui.ImageShader? _goldShader;
  ui.ImageShader? _lacquerShader;

  /// Whether MatCap GPU shaders have been baked.
  bool get isReady => _goldShader != null && _lacquerShader != null;

  /// Synchronously bakes procedural MatCap textures on first access.
  void ensureInitialized() {
    if (_goldShader != null && _lacquerShader != null) {
      return;
    }
    _goldImg = _bakeSphere(isGold: true);
    _lacquerImg = _bakeSphere(isGold: false);
    _goldShader = ui.ImageShader(
      _goldImg!,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      _identityMatrix,
    );
    _lacquerShader = ui.ImageShader(
      _lacquerImg!,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      _identityMatrix,
    );
  }

  /// Returns the cached GPU [ui.ImageShader] for [preset].
  ui.ImageShader shaderFor(MatCapPreset3D preset) {
    ensureInitialized();
    return switch (preset) {
      MatCapPreset3D.metallicGold => _goldShader!,
      MatCapPreset3D.glossyLacquer => _lacquerShader!,
    };
  }

  /// Releases baked GPU [ui.ImageShader]s and [ui.Image]s.
  void dispose() {
    _goldShader?.dispose();
    _lacquerShader?.dispose();
    _goldImg?.dispose();
    _lacquerImg?.dispose();
    _goldShader = null;
    _lacquerShader = null;
    _goldImg = null;
    _lacquerImg = null;
  }

  static ui.Image _bakeSphere({required bool isGold}) {
    const s = resolution;
    final fs = s.toDouble();
    const center = Offset(s * 0.5, s * 0.5);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, fs, fs),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(s * 0.34, s * 0.28),
          s * 0.68,
          isGold
              ? const [
                  Color(0xFFFFFBE8),
                  Color(0xFFF6D36B),
                  Color(0xFFC48B28),
                  Color(0xFF6B4818),
                ]
              : const [
                  Color(0xFFFFFFFF),
                  Color(0xFFDCE6F2),
                  Color(0xFFA9BBD0),
                  Color(0xFF7D8FA6),
                ],
          const [0.0, 0.28, 0.68, 1.0],
        ),
    );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, fs, fs),
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = ui.Gradient.linear(
          const Offset(0, s * 0.55),
          Offset(0, fs),
          isGold
              ? const [Color(0x00000000), Color(0x66FFE082)]
              : const [Color(0x00000000), Color(0x55B3E5FC)],
        ),
    );

    canvas.drawCircle(
      const Offset(s * 0.33, s * 0.27),
      s * 0.20,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(
          const Offset(s * 0.33, s * 0.27),
          s * 0.20,
          const [
            Color(0xEEFFFFFF),
            Color(0x55FFF9E6),
            Color(0x00FFFFFF),
          ],
          const [0.0, 0.45, 1.0],
        ),
    );

    canvas.drawCircle(
      center,
      s * 0.47,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8)
        ..color = isGold ? const Color(0x66FFF3C4) : const Color(0x55E1F5FE),
    );

    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(s, s);
    } finally {
      picture.dispose();
    }
  }
}
