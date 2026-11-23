import 'dart:math' as math;
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// {@template ribbon_material_3d}
/// Material for camera-facing 3D ribbons and strokes drawn by
/// `RibbonTrail3D` and `StrokeBatch3D`.
/// {@endtemplate}
class RibbonMaterial3D({
  var Texture? _texture,
  var Color _albedoColor = const Color(0xFFFFFFFF),
  var double _edgeSoftness = 0.35,
  var double _depthBias = 0.0,
  var double _alphaCutoff = 0.0,

  /// Render state (defaults to additive glow).
  RenderState renderState = RenderState.additive,
}) extends Material {
  /// {@macro ribbon_material_3d}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: const [RenderContext3D.cameraMatricesBlock, 'RibbonView'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: const ['RibbonLook', 'albedoTexture'],
        ),
      ) {
    if (kIsWeb) {
      throw UnsupportedError(
        'RibbonMaterial3D is not supported on the web yet',
      );
    }
    setInitialState(renderState: renderState, castsShadows: false);
  }

  static const String _bundle =
      'packages/flame_3d/assets/shaders/ribbon_material.shaderbundle';

  /// Optional strip texture mapped `(u, v)` along and across the ribbon.
  Texture? get texture => _texture;
  set texture(Texture? value) => _texture = noteChange(_texture, value);

  /// Base tint multiplied by each segment's color.
  Color get albedoColor => _albedoColor;
  set albedoColor(Color value) =>
      _albedoColor = noteChange(_albedoColor, value);

  /// Share of each half-width in `[0, 1]` that fades smoothly to zero at the
  /// outer edges.
  double get edgeSoftness => _edgeSoftness;
  set edgeSoftness(double value) =>
      _edgeSoftness = noteChange(_edgeSoftness, value);

  /// Clip-space depth bias (`>= 0`) pulling ribbons slightly towards the
  /// camera.
  double get depthBias => _depthBias;
  set depthBias(double value) => _depthBias = noteChange(_depthBias, value);

  /// Fragments whose final alpha is below [alphaCutoff] are discarded.
  double get alphaCutoff => _alphaCutoff;
  set alphaCutoff(double value) =>
      _alphaCutoff = noteChange(_alphaCutoff, value);

  final Vector4 _viewer = Vector4.zero();
  final Vector4 _eye = Vector4.zero();
  final Vector4 _right = Vector4.zero();
  final Vector4 _params = Vector4.zero();

  /// Ribbon instances hold the end points and widths of a segment, not model
  /// matrices.
  @override
  bool get instancesHoldModelMatrices => false;

  @override
  void apply(RenderContext context) {
    final c = context as RenderContext3D;
    final v = c.view.storage;
    // Row 2 of the rigid view matrix `(v[2], v[6], v[10])` points towards the
    // viewer in world space.
    var bx = v[2];
    var by = v[6];
    var bz = v[10];
    final bLen = math.sqrt(bx * bx + by * by + bz * bz);
    if (bLen > 1e-6) {
      bx /= bLen;
      by /= bLen;
      bz /= bLen;
    } else {
      bx = 0;
      by = 0;
      bz = 1;
    }
    var rx = v[0];
    var ry = v[4];
    var rz = v[8];
    final rLen = math.sqrt(rx * rx + ry * ry + rz * rz);
    if (rLen > 1e-6) {
      rx /= rLen;
      ry /= rLen;
      rz /= rLen;
    } else {
      rx = 1;
      ry = 0;
      rz = 0;
    }
    final proj = c.projection.storage;
    final perspective = proj[3] != 0 || proj[7] != 0 || proj[11] != 0;
    final eye = c.cameraPosition;

    _viewer.setValues(bx, by, bz, perspective ? 1.0 : 0.0);
    _eye.setValues(eye.x, eye.y, eye.z, depthBias);
    _right.setValues(rx, ry, rz, 0.0);
    vertexShader
      ..setVector4('RibbonView.viewer', _viewer)
      ..setVector4('RibbonView.eye', _eye)
      ..setVector4('RibbonView.right', _right);

    final tex = texture;
    final blend = renderState.blend;
    final premultiplied = blend != BlendState.alpha;
    _params.setValues(
      edgeSoftness,
      premultiplied ? 1.0 : 0.0,
      tex == null ? 0.0 : 1.0,
      alphaCutoff,
    );
    fragmentShader
      ..setTexture('albedoTexture', tex ?? Texture.standard)
      ..setColor('RibbonLook.albedoColor', albedoColor)
      ..setVector4('RibbonLook.params', _params);
  }

  @override
  void visitTextures(void Function(Texture texture) visitor) {
    if (texture case final tex?) {
      visitor(tex);
    }
  }
}
