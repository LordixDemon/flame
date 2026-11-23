import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/resources/material/material_apply_cache.dart';

/// {@template unlit_material}
/// A material that renders textures without any lighting calculations.
///
/// Unlike [SpatialMaterial], this material outputs the texture color multiplied
/// by [albedoColor], by the vertex color and by the per-instance color
/// directly, with no PBR shading, tone mapping, or gamma correction. This makes
/// it ideal for:
///
/// - 2D canvas content rendered onto 3D surfaces
/// - UI panels and HUD elements in 3D space
/// - Emissive/self-lit surfaces
/// - Sky boxes and debug rendering
///
/// Its output may be translucent, so by default it blends with premultiplied
/// alpha and is drawn as translucent (after the opaque draws, back to front;
/// draws of one surface that are consecutive in that order are still
/// batched) while still writing depth. Set [renderState] to
/// [RenderState.opaque] for opaque content, so that it is sorted and batched
/// with the opaque draws.
/// {@endtemplate}
class UnlitMaterial({
  var Color _albedoColor = const Color(0xFFFFFFFF),
  Texture? albedoTexture,
}) extends Material {
  /// {@macro unlit_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'packages/flame_3d/assets/shaders/unlit_material.shaderbundle',
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'packages/flame_3d/assets/shaders/unlit_material.shaderbundle',
          slots: ['albedoTexture', 'Material'],
        ),
      ) {
    setInitialState(
      renderState: const RenderState(blend: BlendState.premultipliedAlpha),
    );
  }

  /// The material's base color, multiplied with [albedoTexture].
  Color get albedoColor => _albedoColor;
  set albedoColor(Color value) =>
      _albedoColor = noteChange(_albedoColor, value);

  /// The texture to render. Multiplied by [albedoColor].
  Texture get albedoTexture => _albedoTexture;
  set albedoTexture(Texture value) =>
      _albedoTexture = noteChange(_albedoTexture, value);
  Texture _albedoTexture = albedoTexture ?? Texture.standard;

  final SimpleApplyCache _applyCache = SimpleApplyCache();
  Shader? _cachedFrag;
  int _cachedFragGen = -1;
  int _texIdx = -1;
  UniformBlock? _matBlock;
  int _albedoColorOff = UniformBlock.missingOffset;

  @override
  bool get hasPassStableFragmentShader => runtimeType == UnlitMaterial;

  @override
  bool get cachesApply => runtimeType == UnlitMaterial;

  @override
  void invalidateApplyCache() => _applyCache.invalidate();

  @override
  bool isApplyCacheValid(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => _applyCache.isValid(version, fragmentShader);

  @override
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => _applyCache.record(version, fragmentShader);

  @override
  void apply(RenderContext context) {
    final frag = fragmentShader;
    frag.resource;
    if (!identical(_cachedFrag, frag) || _cachedFragGen != frag.generation) {
      _cachedFrag = frag;
      _cachedFragGen = frag.generation;
      _texIdx = frag.samplerIndexOf('albedoTexture');
      final matIdx = frag.blockIndexOf('Material');
      _matBlock = matIdx >= 0 ? frag.blockAt(matIdx) : null;
      _albedoColorOff = _matBlock?.resolveOffset('albedoColor') ?? -1;
    }
    if (_texIdx >= 0) {
      frag.setTextureAt(_texIdx, albedoTexture);
    } else {
      frag.setTexture('albedoTexture', albedoTexture);
    }
    if (_albedoColorOff >= 0) {
      _matBlock!.writeColorAt(_albedoColorOff, albedoColor);
    } else {
      frag.setColor('Material.albedoColor', albedoColor);
    }
  }

  @override
  void visitTextures(void Function(Texture texture) visitor) {
    visitor(albedoTexture);
  }
}
