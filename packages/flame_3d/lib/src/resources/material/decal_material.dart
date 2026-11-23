import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// {@template decal_material}
/// Material for flat 3D surface decals (targeting rings, footprints, scorch
/// marks, puddles, drop shadows) drawn with `DecalBatch3D` or [PlaneMesh].
/// {@endtemplate}
class DecalMaterial({
  var Texture? _texture,
  var Color _albedoColor = const Color(0xFFFFFFFF),
  var double _depthBias = 0.0005,
  var double _softness = 0.15,
  var double _innerRadius = 0.0,
  var double _alphaCutoff = 0.001,

  /// Render state (defaults to premultiplied alpha without depth writes).
  RenderState renderState = RenderState.premultipliedAlphaBlend,

  var bool _premultipliedTexture = false,
}) extends Material {
  /// {@macro decal_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: const [RenderContext3D.cameraMatricesBlock, 'Decal'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: const ['Decal', 'albedoTexture'],
        ),
      ) {
    if (kIsWeb) {
      throw UnsupportedError('DecalMaterial is not supported on the web yet');
    }
    setInitialState(renderState: renderState, castsShadows: false);
  }

  /// Optional decal or atlas texture (`null` draws a procedural disc/ring).
  Texture? get texture => _texture;
  set texture(Texture? value) => _texture = noteChange(_texture, value);

  /// Base color multiplied by each decal's per-instance color.
  Color get albedoColor => _albedoColor;
  set albedoColor(Color value) =>
      _albedoColor = noteChange(_albedoColor, value);

  /// Clip-space depth bias (`>= 0`) preventing coplanar Z-fighting.
  double get depthBias => _depthBias;
  set depthBias(double value) => _depthBias = noteChange(_depthBias, value);

  /// Radial edge softness in `[0, 1]` (feathering of the procedural disc/ring,
  /// or circular edge vignette when [texture] is set).
  double get softness => _softness;
  set softness(double value) => _softness = noteChange(_softness, value);

  /// Inner radius in `[0, 1)` when drawing a procedural ring (`0` draws a
  /// filled disc).
  double get innerRadius => _innerRadius;
  set innerRadius(double value) =>
      _innerRadius = noteChange(_innerRadius, value);

  /// Fragments with final alpha below [alphaCutoff] are discarded.
  double get alphaCutoff => _alphaCutoff;
  set alphaCutoff(double value) =>
      _alphaCutoff = noteChange(_alphaCutoff, value);

  /// Whether [texture] holds premultiplied colors, as the images Flutter
  /// decodes and atlases built by drawing them do.
  ///
  /// With `false` (the default) the texels are taken as straight colors and
  /// multiplied by their alpha. With `true` they are taken as premultiplied
  /// and scaled as a whole by the edge softness and the tint's alpha, then
  /// tinted, so the filtered and mipmapped texels of a premultiplied atlas
  /// keep their colors instead of darkening at translucent edges. It has no
  /// effect on the procedural disc and ring (no [texture]).
  bool get premultipliedTexture => _premultipliedTexture;
  set premultipliedTexture(bool value) =>
      _premultipliedTexture = noteChange(_premultipliedTexture, value);

  static const String _bundle =
      'packages/flame_3d/assets/shaders/decal_material.shaderbundle';

  final Vector4 _params = Vector4.zero();
  final Vector4 _cutoff = Vector4.zero();

  @override
  void visitTextures(void Function(Texture texture) visitor) {
    if (texture case final tex?) {
      visitor(tex);
    }
  }

  @override
  void apply(RenderContext context) {
    final tex = texture;
    _params.setValues(
      depthBias,
      softness,
      innerRadius,
      tex == null ? 1.0 : 0.0,
    );
    _cutoff.setValues(alphaCutoff, premultipliedTexture ? 1.0 : 0.0, 0, 0);
    vertexShader
      ..setColor('Decal.albedoColor', albedoColor)
      ..setVector4('Decal.params', _params)
      ..setVector4('Decal.cutoff', _cutoff);
    fragmentShader
      ..setTexture('albedoTexture', tex ?? Texture.standard)
      ..setColor('Decal.albedoColor', albedoColor)
      ..setVector4('Decal.params', _params)
      ..setVector4('Decal.cutoff', _cutoff);
  }
}
