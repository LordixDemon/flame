import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Orientation mode for sprites in a `BillboardBatch3D`.
enum BillboardOrientation3D() {
  /// Faces the camera plane on both axes (icons, floating text, FX).
  spherical,

  /// Rotates around an upright axis to face the camera horizontally, with an
  /// optional HD-2D standee backward tilt.
  cylindrical,
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
  var Color albedoColor = const Color(0xFFFFFFFF),
  var double alphaCutoff = 0.4,
  var double shadeWeight = 0.65,
  var bool ditherFade = false,
  bool translucent = false,

  /// Whether the colors of [albedoTexture] are premultiplied by their alpha.
  ///
  /// Textures made from a `dart:ui` `Image` (`ImageTexture.create`, decoded
  /// assets, rasterized pictures) are, and so is the default. Set it to
  /// `false` for a texture built from straight-alpha bytes. The shader
  /// divides premultiplied texels by their alpha before tinting and
  /// lighting them, so that translucent and cut-out edges keep their color
  /// instead of darkening.
  var bool premultipliedTexture = true,
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
          ],
        ),
      ) {
    castsShadows = false;
    if (translucent) {
      alphaCutoff = 0.0;
      renderState = RenderState.premultipliedAlphaBlend;
    } else {
      renderState = RenderState.opaque;
    }
  }

  static const String _bundle =
      'packages/flame_3d/assets/shaders/billboard_material.shaderbundle';

  Texture albedoTexture = albedoTexture ?? Texture.standard;

  static final Vector3 _right = Vector3.zero();
  static final Vector3 _up = Vector3.zero();
  static final Vector3 _back = Vector3.zero();
  static final Vector4 _vec = Vector4.zero();

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
  void apply(RenderContext context) {
    _writeFrame(context as RenderContext3D, vertexShader);
    // 1 when blending premultiplied colors, plus 2 when the texture holds
    // premultiplied colors.
    final blendFlags =
        (renderState.blend == BlendState.premultipliedAlpha ? 1.0 : 0.0) +
        (premultipliedTexture ? 2.0 : 0.0);
    fragmentShader
      ..setTexture('albedoTexture', albedoTexture)
      ..setColor('BillboardLook.albedoColor', albedoColor)
      ..setVector4(
        'BillboardLook.params',
        _vec..setValues(
          alphaCutoff,
          shadeWeight,
          blendFlags,
          ditherFade ? 1.0 : 0.0,
        ),
      );
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

    vertexShader
      ..setVector4(
        'BillboardFrame.camRight',
        _vec..setValues(_right.x, _right.y, _right.z, 0),
      )
      ..setVector4(
        'BillboardFrame.camUp',
        _vec..setValues(_up.x, _up.y, _up.z, 0),
      )
      ..setVector4(
        'BillboardFrame.camBack',
        _vec..setValues(_back.x, _back.y, _back.z, 0),
      );
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

  @override
  void apply(RenderContext context) {
    BillboardMaterial3D._writeFrame(context as RenderContext3D, vertexShader);
    final source = _source;
    fragmentShader
      ..setTexture('albedoTexture', source.albedoTexture)
      ..setVector4(
        'BillboardDepthLook.params',
        BillboardMaterial3D._vec..setValues(
          source.alphaCutoff,
          source.albedoColor.a,
          0,
          source.ditherFade ? 1.0 : 0.0,
        ),
      );
  }
}
