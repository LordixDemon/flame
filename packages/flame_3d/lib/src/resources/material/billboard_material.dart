import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/resources/material/material_apply_cache.dart';

const bool _kIsWeb = identical(0, 0.0);

/// Orientation mode for sprites in a `BillboardBatch3D`.
enum BillboardOrientation3D() {
  /// Faces the camera plane on both axes (icons, floating text, FX).
  spherical,

  /// Rotates around an upright axis to face the camera horizontally, with an
  /// optional HD-2D standee backward tilt.
  cylindrical,

  /// Does not turn towards the camera: lies in the plane of its up axis and
  /// its right axis, like a sign.
  fixed,
}

/// Material used by `BillboardBatch3D` and `Text3DComponent` to render
/// depth-buffered HD-2D sprites, standees, and world-space labels.
///
/// Texels whose alpha is below [alphaCutoff] are discarded and the rest is
/// drawn opaque, writing depth. With `translucent: true` there is no cutoff
/// and the sprites are blended with [RenderState.premultipliedAlphaBlend],
/// without writing depth.
class BillboardMaterial3D({
  Texture? albedoTexture,
  var Color _albedoColor = const Color(0xFFFFFFFF),
  var double _alphaCutoff = 0.4,
  var double _shadeWeight = 0.65,
  var bool _ditherFade = false,
  bool translucent = false,

  var bool _premultipliedTexture = true,
}) extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: [RenderContext3D.cameraMatricesBlock, 'BillboardFrame'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: [
            'albedoTexture',
            'BillboardLook',
            RenderContext3D.ambientLightBlock,
            RenderContext3D.lightsBlock,
            RenderContext3D.directionalLightsBlock,
            RenderContext3D.spotLightsBlock,
            RenderContext3D.hemisphereLightBlock,
            RenderContext3D.cameraBlock,
            RenderContext3D.fogBlock,
            // The WebGPU bundle reads no light grid.
            if (!_kIsWeb) ...[
              RenderContext3D.lightGridBlock,
              RenderContext3D.lightGridSampler,
            ],
          ],
        ),
      ) {
    if (translucent) {
      _alphaCutoff = 0.0;
    }
    setInitialState(
      renderState: translucent
          ? RenderState.premultipliedAlphaBlend
          : RenderState.opaque,
      castsShadows: false,
    );
  }

  Color get albedoColor => _albedoColor;
  set albedoColor(Color value) =>
      _albedoColor = noteChange(_albedoColor, value);

  double get alphaCutoff => _alphaCutoff;
  set alphaCutoff(double value) =>
      _alphaCutoff = noteChange(_alphaCutoff, value);

  double get shadeWeight => _shadeWeight;
  set shadeWeight(double value) =>
      _shadeWeight = noteChange(_shadeWeight, value);

  bool get ditherFade => _ditherFade;
  set ditherFade(bool value) => _ditherFade = noteChange(_ditherFade, value);

  /// Whether the colors of [albedoTexture] are premultiplied by their alpha.
  ///
  /// Textures made from a `dart:ui` `Image` (`ImageTexture.create`, decoded
  /// assets, rasterized pictures) are, and so is the default. Set it to
  /// `false` for a texture built from straight-alpha bytes. The shader
  /// divides premultiplied texels by their alpha before tinting and
  /// lighting them, so that translucent and cut-out edges keep their color
  /// instead of darkening.
  bool get premultipliedTexture => _premultipliedTexture;
  set premultipliedTexture(bool value) =>
      _premultipliedTexture = noteChange(_premultipliedTexture, value);

  static const String _bundle =
      'packages/flame_3d/assets/shaders/billboard_material.shaderbundle';

  /// The texture of the billboards, multiplied by [albedoColor].
  Texture get albedoTexture => _albedoTexture;
  set albedoTexture(Texture value) =>
      _albedoTexture = noteChange(_albedoTexture, value);
  Texture _albedoTexture = albedoTexture ?? Texture.standard;

  static final Vector3 _right = Vector3.zero();
  static final Vector3 _up = Vector3.zero();
  static final Vector3 _back = Vector3.zero();

  /// Billboard instances hold a center, an up axis and a size, not model
  /// matrices: the opaque ones reach the depth-normal prepass through
  /// [depthNormalMaterial].
  @override
  bool get instancesHoldModelMatrices => false;

  /// Draws the opaque billboards of this material in the depth-normal
  /// prepass, placed and cut out as in the main pass.
  @override
  Material? get depthNormalMaterial => renderState.translucent
      ? null
      : (_depthNormalMaterial ??= _BillboardDepthNormalMaterial(this));
  _BillboardDepthNormalMaterial? _depthNormalMaterial;

  @override
  void visitTextures(void Function(Texture texture) visitor) {
    visitor(albedoTexture);
  }

  final SimpleApplyCache _fragApplyCache = SimpleApplyCache();
  Shader? _cachedFrag;
  int _cachedFragGen = -1;
  int _albedoTexIdx = -1;

  @override
  void apply(RenderContext context) {
    _writeFrame(context as RenderContext3D, vertexShader);
    final frag = fragmentShader..resource;
    if (_fragApplyCache.isValid(version, frag)) {
      return;
    }
    _fragApplyCache.record(version, frag);

    if (!identical(_cachedFrag, frag) || _cachedFragGen != frag.generation) {
      _cachedFrag = frag;
      _cachedFragGen = frag.generation;
      _albedoTexIdx = frag.samplerIndexOf('albedoTexture');
    }
    if (_albedoTexIdx >= 0) {
      frag.setTextureAt(_albedoTexIdx, albedoTexture);
    } else {
      frag.setTexture('albedoTexture', albedoTexture);
    }

    // 1 when blending premultiplied colors, plus 2 when the texture holds
    // premultiplied colors.
    final blendFlags =
        (renderState.blend == BlendState.premultipliedAlpha ? 1.0 : 0.0) +
        (premultipliedTexture ? 2.0 : 0.0);
    final idx = frag.blockIndexOf('BillboardLook');
    if (idx >= 0) {
      final block = frag.blockAt(idx);
      final off =
          (block.cachedWriterOffsets as _BillboardLookOffsets?) ??
          (block.cachedWriterOffsets = _BillboardLookOffsets(block));
      if (off._albedoColor >= 0) {
        block.writeColorAt(off._albedoColor, albedoColor);
      }
      if (off._params >= 0) {
        block.writeVec4ValuesAt(
          off._params,
          alphaCutoff,
          shadeWeight,
          blendFlags,
          ditherFade ? 1.0 : 0.0,
        );
      }
    }
  }

  /// Writes the camera's right, up and back directions, as the billboards of
  /// the pass see them, into the `BillboardFrame` block of [vertexShader].
  static void _writeFrame(RenderContext3D ctx3d, Shader vertexShader) {
    final view = ctx3d.view.storage;
    final vp = ctx3d.viewProjection.storage;
    _right.setValues(view[0], view[4], view[8]);
    if (vp[0] * _right.x + vp[4] * _right.y + vp[8] * _right.z < 0) {
      _right.negate();
    }
    _up.setValues(view[1], view[5], view[9]);
    if (vp[1] * _up.x + vp[5] * _up.y + vp[9] * _up.z < 0) {
      _up.negate();
    }
    _back.setValues(view[2], view[6], view[10]);
    if (_right.length2 > 1e-12) {
      _right.normalize();
    }
    if (_up.length2 > 1e-12) {
      _up.normalize();
    }
    if (_back.length2 > 1e-12) {
      _back.normalize();
    }

    vertexShader.resource;
    final idx = vertexShader.blockIndexOf('BillboardFrame');
    if (idx < 0) {
      return;
    }
    final block = vertexShader.blockAt(idx);
    final off =
        (block.cachedWriterOffsets as _BillboardFrameOffsets?) ??
        (block.cachedWriterOffsets = _BillboardFrameOffsets(block));
    if (off._camRight >= 0) {
      block.writeVec4ValuesAt(off._camRight, _right.x, _right.y, _right.z, 0);
    }
    if (off._camUp >= 0) {
      block.writeVec4ValuesAt(off._camUp, _up.x, _up.y, _up.z, 0);
    }
    if (off._camBack >= 0) {
      block.writeVec4ValuesAt(off._camBack, _back.x, _back.y, _back.z, 0);
    }
  }
}

/// Draws the billboards of [_source] in the depth-normal prepass.
class _BillboardDepthNormalMaterial(final BillboardMaterial3D _source)
    extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: [RenderContext3D.cameraMatricesBlock, 'BillboardFrame'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: ['albedoTexture', 'BillboardDepthLook'],
        ),
      );

  static const String _bundle =
      'packages/flame_3d/assets/shaders/billboard_depth_normal.shaderbundle';

  final SimpleApplyCache _fragApplyCache = SimpleApplyCache();
  Shader? _cachedFrag;
  int _cachedFragGen = -1;
  int _albedoTexIdx = -1;

  @override
  void apply(RenderContext context) {
    BillboardMaterial3D._writeFrame(context as RenderContext3D, vertexShader);
    final source = _source;
    final frag = fragmentShader..resource;
    if (_fragApplyCache.isValid(source.version, frag)) {
      return;
    }
    _fragApplyCache.record(source.version, frag);

    if (!identical(_cachedFrag, frag) || _cachedFragGen != frag.generation) {
      _cachedFrag = frag;
      _cachedFragGen = frag.generation;
      _albedoTexIdx = frag.samplerIndexOf('albedoTexture');
    }
    if (_albedoTexIdx >= 0) {
      frag.setTextureAt(_albedoTexIdx, source.albedoTexture);
    } else {
      frag.setTexture('albedoTexture', source.albedoTexture);
    }

    final idx = frag.blockIndexOf('BillboardDepthLook');
    if (idx >= 0) {
      final block = frag.blockAt(idx);
      final off =
          (block.cachedWriterOffsets as _BillboardDepthLookOffsets?) ??
          (block.cachedWriterOffsets = _BillboardDepthLookOffsets(block));
      if (off._params >= 0) {
        block.writeVec4ValuesAt(
          off._params,
          source.alphaCutoff,
          source.albedoColor.a,
          0,
          source.ditherFade ? 1.0 : 0.0,
        );
      }
    }
  }
}

class _BillboardFrameOffsets(final UniformBlock _b) {
  late final int _camRight = _b.resolveOffset('camRight');
  late final int _camUp = _b.resolveOffset('camUp');
  late final int _camBack = _b.resolveOffset('camBack');
}

class _BillboardLookOffsets(final UniformBlock _b) {
  late final int _albedoColor = _b.resolveOffset('albedoColor');
  late final int _params = _b.resolveOffset('params');
}

class _BillboardDepthLookOffsets(final UniformBlock _b) {
  late final int _params = _b.resolveOffset('params');
}
