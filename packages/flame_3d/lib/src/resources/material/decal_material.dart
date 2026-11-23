import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/resources/material/material_apply_cache.dart';
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

  final MultiVariantApplyCache _applyCache = MultiVariantApplyCache(1);
  Shader? _cachedFrag;
  int _cachedFragGen = -1;
  int _albedoTexIdx = -1;

  @override
  bool get hasPassStableFragmentShader => runtimeType == DecalMaterial;

  @override
  bool get cachesApply => runtimeType == DecalMaterial;

  @override
  void invalidateApplyCache() => _applyCache.invalidate();

  @override
  bool isApplyCacheValid(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => _applyCache.isValid(
    version: version,
    vertexShader: vertexShader,
    fragmentShader: fragmentShader,
    variantSlot: identical(vertexShader, super.vertexShader) ? 0 : -1,
  );

  @override
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => _applyCache.record(
    version: version,
    vertexShader: vertexShader,
    fragmentShader: fragmentShader,
    variantSlot: identical(vertexShader, super.vertexShader) ? 0 : -1,
  );

  @override
  void visitTextures(void Function(Texture texture) visitor) {
    if (texture case final tex?) {
      visitor(tex);
    }
  }

  void _writeDecalBlock(
    Shader shader,
    double hasProceduralMask,
    double premulFlag,
  ) {
    final idx = shader.blockIndexOf('Decal');
    if (idx < 0) {
      return;
    }
    final block = shader.blockAt(idx);
    final off =
        (block.cachedWriterOffsets as _DecalOffsets?) ??
        (block.cachedWriterOffsets = _DecalOffsets(block));
    if (off._albedoColor >= 0) {
      block.writeColorAt(off._albedoColor, albedoColor);
    }
    if (off._params >= 0) {
      block.writeVec4ValuesAt(
        off._params,
        depthBias,
        softness,
        innerRadius,
        hasProceduralMask,
      );
    }
    if (off._cutoff >= 0) {
      block.writeVec4ValuesAt(off._cutoff, alphaCutoff, premulFlag, 0, 0);
    }
  }

  @override
  void apply(RenderContext context) {
    final tex = texture;
    final proceduralFlag = tex == null ? 1.0 : 0.0;
    final premulFlag = premultipliedTexture ? 1.0 : 0.0;

    final vert = vertexShader..resource;
    _writeDecalBlock(vert, proceduralFlag, premulFlag);

    final frag = fragmentShader..resource;
    if (!identical(_cachedFrag, frag) || _cachedFragGen != frag.generation) {
      _cachedFrag = frag;
      _cachedFragGen = frag.generation;
      _albedoTexIdx = frag.samplerIndexOf('albedoTexture');
    }
    if (_albedoTexIdx >= 0) {
      frag.setTextureAt(_albedoTexIdx, tex ?? Texture.standard);
    } else {
      frag.setTexture('albedoTexture', tex ?? Texture.standard);
    }
    _writeDecalBlock(frag, proceduralFlag, premulFlag);
  }
}

class _DecalOffsets(final UniformBlock _b) {
  late final int _albedoColor = _b.resolveOffset('albedoColor');
  late final int _params = _b.resolveOffset('params');
  late final int _cutoff = _b.resolveOffset('cutoff');
}
