import 'dart:math' as math;
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

const bool _kIsWeb = identical(0, 0.0);

/// {@template spatial_material}
/// Physically-based Cook-Torrance metallic-roughness material supporting full
/// glTF 2.0 maps ([albedoTexture], vertex-tangent or cotangent [normalTexture],
/// [metallicRoughnessTexture], [occlusionTexture], [emissiveTexture], UV1
/// [lightmapTexture]), Karis Split-Sum `BrdfLut3D` + prefiltered roughness-mip
/// + Kulla–Conty multi-scattering IBL reflections ([environmentTexture],
/// [environmentProbe], local box-projected `ReflectionProbeVolume3D`, and 3D
/// `LightProbeGrid3D`), [clearcoat], dielectric [transmission] / [ior]
/// Grab-Pass refraction, unified 4-Cascade CSM + Multi-Spot + Dual-Paraboloid
/// Point shadows, [FogSettings], `MASK` [alphaCutoff], `4x4` Bayer
/// [ditherFade], and HDR output (extended-range sRGB, see
/// `World3D.hdrEnabled`).
/// {@endtemplate}
class SpatialMaterial({
  /// Base color multiplier (`rgb` and `a`).
  var Color albedoColor = const Color(0xFFFFFFFF),
  Texture? albedoTexture,
  var double metallic = 0.8,
  var double roughness = 0.6,

  /// Optional tangent-space RGB normal map (uses `vertexTangent`
  /// when present in the surface's `VertexLayout`, or a screen-space cotangent
  /// frame otherwise).
  var Texture? normalTexture,

  /// Strength multiplier applied to the XY perturbation of [normalTexture].
  var double normalScale = 1.0,

  /// Optional glTF metallic-roughness map (`G` = roughness, `B` = metallic).
  var Texture? metallicRoughnessTexture,

  /// Optional ambient-occlusion map (`R` channel).
  var Texture? occlusionTexture,

  /// Blend factor `[0..1]` for [occlusionTexture].
  var double occlusionStrength = 1.0,

  /// Emissive color added before tone mapping (`0xFF000000` = no emission).
  var Color emissiveColor = const Color(0xFF000000),

  /// Multiplier on [emissiveColor] and [emissiveTexture].
  var double emissiveStrength = 1.0,

  /// Optional emissive RGB texture multiplied by [emissiveColor].
  var Texture? emissiveTexture,

  /// Optional equirectangular environment reflection map sampled along the
  /// view reflection vector.
  var Texture? environmentTexture,

  /// Reflection strength for [environmentTexture] (`0` when unset).
  var double environmentIntensity = 1.0,

  /// Optional pre-filtered `SH9` diffuse irradiance + specular reflection
  /// probe (`EnvironmentProbe3D`).
  var EnvironmentProbe3D? environmentProbe,

  /// Optional baked diffuse lightmap texture sampled with secondary UV channel
  /// `vertexTexCoord1` (`TEXCOORD_1`, falling back to `vertexTexCoord`).
  var Texture? lightmapTexture,

  /// Multiplier applied to [lightmapTexture].
  var double lightmapIntensity = 1.0,

  /// Clearcoat layer intensity (`0..1`, `F0 = 0.04` polyurethane/car-paint
  /// specular coat).
  var double clearcoat = 0.0,

  /// Perceptual roughness (`0.04..1.0`) of the [clearcoat] layer.
  var double clearcoatRoughness = 0.1,

  /// Dielectric physical transmission factor (`0..1` for refractive glass).
  var double transmission = 0.0,

  /// Index of refraction (`1.0..3.0`; `1.5` = crown glass, `F0 = 0.04`).
  var double ior = 1.5,

  /// UV scale (`(1, 1)` by default).
  Vector2? uvScale,

  /// UV offset (`(0, 0)` by default).
  Vector2? uvOffset,

  /// Alpha threshold below which fragments are discarded (`0` disables cutout).
  var double alphaCutoff = 0.0,

  /// Reverses back-face normals before shading when `CullMode.none` is used.
  var bool doubleSided = false,

  /// Dissolves opaque draws via a `4x4` Bayer screen-space dither pattern.
  var bool ditherFade = false,

  /// Convenience flag configuring [renderState] for translucent blending (with
  /// [RenderState.singlePieceAlphaBlend] when `singlePieceTranslucent` is
  /// `true`).
  bool translucent = false,
  bool singlePieceTranslucent = false,
}) extends Material {
  /// {@macro spatial_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _kIsWeb ? _webBundle : _pbrBundle,
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _kIsWeb ? _webBundle : _pbrBundle,
          slots: _kIsWeb ? _webFragmentSlots : _pbrFragmentSlots,
        ),
      ) {
    final needsTranslucent = translucent || transmission > 1e-4;
    if (doubleSided && !needsTranslucent) {
      renderState = RenderState.opaque;
    }
    if (needsTranslucent) {
      final base = singlePieceTranslucent
          ? RenderState.singlePieceAlphaBlend
          : RenderState.alphaBlend;
      renderState = (transmission > 1e-4 && !doubleSided)
          ? base.copyWith(cullMode: CullMode.backFace)
          : base;
    }
  }

  static const String _webBundle =
      'packages/flame_3d/assets/shaders/spatial_material.shaderbundle';
  static const String _pbrBundle =
      'packages/flame_3d/assets/shaders/spatial_material_pbr.shaderbundle';
  static const String _pbrTangentBundle =
      'packages/flame_3d/assets/shaders/'
      'spatial_material_pbr_tangent.shaderbundle';

  static const List<String> _webFragmentSlots = [
    'albedoTexture',
    'normalTexture',
    'metallicRoughnessTexture',
    'occlusionTexture',
    'emissiveTexture',
    'environmentTexture',
    RenderContext3D.shadowMapSampler,
    'Material',
    RenderContext3D.ambientLightBlock,
    RenderContext3D.lightsBlock,
    RenderContext3D.directionalLightsBlock,
    RenderContext3D.spotLightsBlock,
    RenderContext3D.hemisphereLightBlock,
    RenderContext3D.cameraBlock,
    RenderContext3D.shadowsBlock,
    RenderContext3D.fogBlock,
  ];

  static const List<String> _pbrFragmentSlots = [
    'albedoTexture',
    'normalTexture',
    'metallicRoughnessTexture',
    'occlusionTexture',
    'emissiveTexture',
    'environmentTexture',
    'lightmapTexture',
    RenderContext3D.brdfLutSampler,
    RenderContext3D.probeGridSampler,
    RenderContext3D.sceneColorSampler,
    RenderContext3D.shadowMapSampler,
    'Material',
    RenderContext3D.passOptionsBlock,
    RenderContext3D.ambientLightBlock,
    RenderContext3D.lightsBlock,
    RenderContext3D.directionalLightsBlock,
    RenderContext3D.spotLightsBlock,
    RenderContext3D.hemisphereLightBlock,
    RenderContext3D.cameraBlock,
    RenderContext3D.shadowsBlock,
    RenderContext3D.fogBlock,
  ];

  Shader? _tangentVertexShader;

  @override
  Shader vertexShaderFor(VertexLayout layout) {
    if (!_kIsWeb &&
        layout.attribute(VertexLayout.tangentAttribute) != null &&
        layout.attribute(VertexLayout.texCoord1Attribute) != null) {
      return _tangentVertexShader ??= VertexShader.fromAsset(
        _pbrTangentBundle,
        slots: [
          RenderContext3D.cameraMatricesBlock,
          RenderContext3D.jointMatricesBlock,
        ],
      );
    }
    return vertexShader;
  }

  /// Base albedo texture multiplied by [albedoColor].
  Texture albedoTexture = albedoTexture ?? Texture.standard;

  /// UV tiling scale.
  Vector2 uvScale = uvScale ?? Vector2.all(1);

  /// UV translation offset.
  Vector2 uvOffset = uvOffset ?? Vector2.zero();

  static final Vector4 _emissiveVec = Vector4.zero();
  static final Vector4 _uvVec = Vector4.zero();
  static final Vector4 _paramsVec = Vector4.zero();
  static final Vector4 _flagsVec = Vector4.zero();
  static final Vector4 _flags2Vec = Vector4.zero();
  static final Vector4 _pbrExtVec = Vector4.zero();
  static final Vector4 _iblParamsVec = Vector4.zero();
  static final Vector4 _shScratch = Vector4.zero();
  static final Vector4 _probeBoxMinVec = Vector4.zero();
  static final Vector4 _probeBoxMaxVec = Vector4.zero();
  static final Vector4 _probeCenterVec = Vector4.zero();

  /// `true` when the material has neither an [environmentTexture] nor an
  /// [environmentProbe]: it then takes its environment from the
  /// `ReflectionProbeVolume3D` around each object it draws.
  @override
  bool get usesReflectionProbes =>
      environmentProbe == null && environmentTexture == null;

  @override
  void apply(RenderContext context) {
    final normTex = normalTexture;
    final ormTex = metallicRoughnessTexture;
    final occTex = occlusionTexture;
    final emiTex = emissiveTexture;
    final lmTex = lightmapTexture;

    // Without an environment of its own, the material uses the volume the
    // render context chose for the drawn object, faded by its weight there.
    var probe = environmentProbe;
    ReflectionProbeVolume3D? volume;
    var volumeWeight = 1.0;
    if (probe == null &&
        environmentTexture == null &&
        context is RenderContext3D) {
      volume = context.reflectionProbe;
      if (volume != null) {
        probe = volume.probe;
        volumeWeight = context.reflectionProbeWeight;
      }
    }

    final envTex = environmentTexture ?? probe?.reflectionTexture;
    final premul = renderState.blend == BlendState.premultipliedAlpha;

    fragmentShader
      ..setTexture('albedoTexture', albedoTexture)
      ..setTexture('normalTexture', normTex ?? Texture.standard)
      ..setTexture('metallicRoughnessTexture', ormTex ?? Texture.standard)
      ..setTexture('occlusionTexture', occTex ?? Texture.standard)
      ..setTexture('emissiveTexture', emiTex ?? Texture.standard)
      ..setTexture('environmentTexture', envTex ?? Texture.standard)
      ..setColor('Material.albedoColor', albedoColor)
      ..setVector4(
        'Material.emissiveColor',
        _emissiveVec..setValues(
          emissiveColor.r * emissiveStrength,
          emissiveColor.g * emissiveStrength,
          emissiveColor.b * emissiveStrength,
          alphaCutoff,
        ),
      )
      ..setVector4(
        'Material.uvTransform',
        _uvVec..setValues(uvScale.x, uvScale.y, uvOffset.x, uvOffset.y),
      )
      ..setVector4(
        'Material.params',
        _paramsVec..setValues(
          metallic,
          roughness,
          normalScale,
          occlusionStrength,
        ),
      )
      ..setVector4(
        'Material.flags',
        _flagsVec..setValues(
          normTex != null ? 1.0 : 0.0,
          ormTex != null ? 1.0 : 0.0,
          occTex != null ? 1.0 : 0.0,
          envTex != null ? environmentIntensity * volumeWeight : 0.0,
        ),
      )
      ..setVector4(
        'Material.flags2',
        _flags2Vec..setValues(
          doubleSided ? 1.0 : 0.0,
          ditherFade ? 1.0 : 0.0,
          premul ? 1.0 : 0.0,
          emiTex != null ? 1.0 : 0.0,
        ),
      );

    if (!_kIsWeb) {
      var maxMip = 0.0;
      if (envTex != null) {
        envTex.resource;
        maxMip = math.max(0, envTex.mipLevelCount - 1).toDouble();
      }
      fragmentShader
        ..setTexture('lightmapTexture', lmTex ?? Texture.standard)
        ..setVector4(
          'Material.pbrExt',
          _pbrExtVec..setValues(
            clearcoat,
            clearcoatRoughness,
            transmission,
            ior,
          ),
        )
        ..setVector4(
          'Material.iblParams',
          _iblParamsVec..setValues(
            lmTex != null ? 1.0 : 0.0,
            lightmapIntensity,
            maxMip,
            envTex != null ? 1.0 : 0.0,
          ),
        );
      if (volume != null) {
        final box = volume.worldBounds;
        final center = volume.worldCenter;
        _probeBoxMinVec.setValues(box.min.x, box.min.y, box.min.z, 0);
        _probeBoxMaxVec.setValues(box.max.x, box.max.y, box.max.z, 0);
        _probeCenterVec.setValues(
          center.x,
          center.y,
          center.z,
          volume.boxProjection ? 1.0 : 0.0,
        );
      } else {
        _probeBoxMinVec.setZero();
        _probeBoxMaxVec.setZero();
        _probeCenterVec.setZero();
      }
      fragmentShader
        ..setVector4('Material.probeBoxMin', _probeBoxMinVec)
        ..setVector4('Material.probeBoxMax', _probeBoxMaxVec)
        ..setVector4('Material.probeCenter', _probeCenterVec);
    }

    // The coefficients give irradiance: like the direct lights, the diffuse
    // light is the irradiance times kD * base / pi.
    final matBlock = fragmentShader.block('Material');
    if (probe != null && probe.intensity > 0) {
      final diffuseScale = probe.intensity * volumeWeight / math.pi;
      for (var i = 0; i < 9; i++) {
        final c = probe.shCoefficients[i];
        matBlock.setVector4(
          'shCoeffs',
          _shScratch..setValues(c.x, c.y, c.z, i == 0 ? diffuseScale : 0.0),
          index: i,
        );
      }
    } else {
      matBlock.setVector4(
        'shCoeffs',
        _shScratch..setZero(),
        index: 0,
      );
    }
  }
}
