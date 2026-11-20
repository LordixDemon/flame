import 'dart:math' as math;
import 'dart:ui' hide FragmentShader;

import 'package:flame/game.dart' show NotifyingVector2;
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart' show debugPrint;

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
///
/// On the web, and on OpenGL ES devices that cannot run its full shader (it
/// samples the environment at explicit mip levels, which needs the
/// `GL_EXT_shader_texture_lod` extension there), it draws with a simpler
/// shader without the IBL, lightmap, clearcoat, transmission and probe
/// inputs: see [usesSimpleShader].
/// {@endtemplate}
class SpatialMaterial({
  var Color _albedoColor = const Color(0xFFFFFFFF),
  Texture? albedoTexture,
  var double _metallic = 0.8,
  var double _roughness = 0.6,
  var Texture? _normalTexture,
  var double _normalScale = 1.0,
  var Texture? _metallicRoughnessTexture,
  var Texture? _occlusionTexture,
  var double _occlusionStrength = 1.0,
  var Color _emissiveColor = const Color(0xFF000000),
  var double _emissiveStrength = 1.0,
  var Texture? _emissiveTexture,
  var Texture? _environmentTexture,
  var double _environmentIntensity = 1.0,
  var EnvironmentProbe3D? _environmentProbe,
  var Texture? _lightmapTexture,
  var double _lightmapIntensity = 1.0,
  var double _clearcoat = 0.0,
  var double _clearcoatRoughness = 0.1,
  var double _transmission = 0.0,
  var double _ior = 1.5,

  /// UV scale (`(1, 1)` by default).
  Vector2? uvScale,

  /// UV offset (`(0, 0)` by default).
  Vector2? uvOffset,

  var double _alphaCutoff = 0.0,
  var bool _doubleSided = false,
  var bool _ditherFade = false,

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
          _simpleShader ? _webBundle : _pbrBundle,
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _simpleShader ? _webBundle : _pbrBundle,
          slots: _simpleShader ? _webFragmentSlots : _pbrFragmentSlots,
        ),
      ) {
    _lastUv.setValues(_uvScale.x, _uvScale.y, _uvOffset.x, _uvOffset.y);
    _uvScale.addListener(_onUvChanged);
    _uvOffset.addListener(_onUvChanged);
    final needsTranslucent = translucent || transmission > 1e-4;
    if (doubleSided && !needsTranslucent) {
      setInitialState(renderState: RenderState.opaque);
    }
    if (needsTranslucent) {
      final base = singlePieceTranslucent
          ? RenderState.singlePieceAlphaBlend
          : RenderState.alphaBlend;
      setInitialState(
        renderState: (transmission > 1e-4 && !doubleSided)
            ? base.copyWith(cullMode: CullMode.backFace)
            : base,
      );
    }
  }

  /// Base color multiplier (`rgb` and `a`).
  Color get albedoColor => _albedoColor;
  set albedoColor(Color value) =>
      _albedoColor = noteChange(_albedoColor, value);

  double get metallic => _metallic;
  set metallic(double value) => _metallic = noteChange(_metallic, value);

  double get roughness => _roughness;
  set roughness(double value) => _roughness = noteChange(_roughness, value);

  /// Optional tangent-space RGB normal map (uses `vertexTangent`
  /// when present in the surface's `VertexLayout`, or a screen-space cotangent
  /// frame otherwise).
  Texture? get normalTexture => _normalTexture;
  set normalTexture(Texture? value) =>
      _normalTexture = noteChange(_normalTexture, value);

  /// Strength multiplier applied to the XY perturbation of [normalTexture].
  double get normalScale => _normalScale;
  set normalScale(double value) =>
      _normalScale = noteChange(_normalScale, value);

  /// Optional glTF metallic-roughness map (`G` = roughness, `B` = metallic).
  Texture? get metallicRoughnessTexture => _metallicRoughnessTexture;
  set metallicRoughnessTexture(Texture? value) =>
      _metallicRoughnessTexture = noteChange(_metallicRoughnessTexture, value);

  /// Optional ambient-occlusion map (`R` channel).
  Texture? get occlusionTexture => _occlusionTexture;
  set occlusionTexture(Texture? value) =>
      _occlusionTexture = noteChange(_occlusionTexture, value);

  /// Blend factor `[0..1]` for [occlusionTexture].
  double get occlusionStrength => _occlusionStrength;
  set occlusionStrength(double value) =>
      _occlusionStrength = noteChange(_occlusionStrength, value);

  /// Emissive color added before tone mapping (`0xFF000000` = no emission).
  Color get emissiveColor => _emissiveColor;
  set emissiveColor(Color value) =>
      _emissiveColor = noteChange(_emissiveColor, value);

  /// Multiplier on [emissiveColor] and [emissiveTexture].
  double get emissiveStrength => _emissiveStrength;
  set emissiveStrength(double value) =>
      _emissiveStrength = noteChange(_emissiveStrength, value);

  /// Optional emissive RGB texture multiplied by [emissiveColor].
  Texture? get emissiveTexture => _emissiveTexture;
  set emissiveTexture(Texture? value) =>
      _emissiveTexture = noteChange(_emissiveTexture, value);

  /// Optional equirectangular environment reflection map sampled along the
  /// view reflection vector.
  Texture? get environmentTexture => _environmentTexture;
  set environmentTexture(Texture? value) =>
      _environmentTexture = noteChange(_environmentTexture, value);

  /// Reflection strength for [environmentTexture] (`0` when unset).
  double get environmentIntensity => _environmentIntensity;
  set environmentIntensity(double value) =>
      _environmentIntensity = noteChange(_environmentIntensity, value);

  /// Optional pre-filtered `SH9` diffuse irradiance + specular reflection
  /// probe (`EnvironmentProbe3D`).
  EnvironmentProbe3D? get environmentProbe => _environmentProbe;
  set environmentProbe(EnvironmentProbe3D? value) =>
      _environmentProbe = noteChange(_environmentProbe, value);

  /// Optional baked diffuse lightmap texture sampled with secondary UV channel
  /// `vertexTexCoord1` (`TEXCOORD_1`, falling back to `vertexTexCoord`).
  Texture? get lightmapTexture => _lightmapTexture;
  set lightmapTexture(Texture? value) =>
      _lightmapTexture = noteChange(_lightmapTexture, value);

  /// Multiplier applied to [lightmapTexture].
  double get lightmapIntensity => _lightmapIntensity;
  set lightmapIntensity(double value) =>
      _lightmapIntensity = noteChange(_lightmapIntensity, value);

  /// Clearcoat layer intensity (`0..1`, `F0 = 0.04` polyurethane/car-paint
  /// specular coat).
  double get clearcoat => _clearcoat;
  set clearcoat(double value) => _clearcoat = noteChange(_clearcoat, value);

  /// Perceptual roughness (`0.04..1.0`) of the [clearcoat] layer.
  double get clearcoatRoughness => _clearcoatRoughness;
  set clearcoatRoughness(double value) =>
      _clearcoatRoughness = noteChange(_clearcoatRoughness, value);

  /// Dielectric physical transmission factor (`0..1` for refractive glass).
  double get transmission => _transmission;
  set transmission(double value) =>
      _transmission = noteChange(_transmission, value);

  /// Index of refraction (`1.0..3.0`; `1.5` = crown glass, `F0 = 0.04`).
  double get ior => _ior;
  set ior(double value) => _ior = noteChange(_ior, value);

  /// Alpha threshold below which fragments are discarded (`0` disables cutout).
  double get alphaCutoff => _alphaCutoff;
  set alphaCutoff(double value) =>
      _alphaCutoff = noteChange(_alphaCutoff, value);

  /// Reverses back-face normals before shading when `CullMode.none` is used.
  bool get doubleSided => _doubleSided;
  set doubleSided(bool value) => _doubleSided = noteChange(_doubleSided, value);

  /// Dissolves opaque draws via a `4x4` Bayer screen-space dither pattern.
  bool get ditherFade => _ditherFade;
  set ditherFade(bool value) => _ditherFade = noteChange(_ditherFade, value);

  /// Whether this material draws with the simpler shader, without the IBL,
  /// lightmap, clearcoat, transmission and reflection probe inputs: on the
  /// web, and on OpenGL ES devices that cannot run the full shader (see
  /// `GpuBackend.shaderSupport`; the choice is made when the material is
  /// created, after `GpuBackend.initialize`).
  bool get usesSimpleShader => identical(fragmentShader.assetName, _webBundle);

  /// Whether new materials use the simpler shader: on the web, or when the
  /// device of the active backend cannot run the full fragment shader but
  /// can run the simpler one.
  static bool get _simpleShader {
    if (_kIsWeb) {
      return true;
    }
    final backend = GpuBackend.activeOrNull;
    if (backend == null) {
      return false;
    }
    final full = backend.shaderSupport(_pbrBundle, _fragmentEntryPoint);
    if (full == null || full.isSupported) {
      return false;
    }
    if (!_warnedSimpleShader) {
      _warnedSimpleShader = true;
      debugPrint(
        'flame_3d: SpatialMaterial uses its simpler shader on this device: '
        'the full one ${full.problems.join('; ')}.',
      );
    }
    return backend
            .shaderSupport(_webBundle, _fragmentEntryPoint)
            ?.isSupported ??
        true;
  }

  static bool _warnedSimpleShader = false;
  static const String _fragmentEntryPoint = 'TextureFragment';

  static const String _webBundle =
      'packages/flame_3d/assets/shaders/spatial_material.shaderbundle';
  static const String _pbrBundle =
      'packages/flame_3d/assets/shaders/spatial_material_pbr.shaderbundle';
  static const String _pbrTangentBundle =
      'packages/flame_3d/assets/shaders/'
      'spatial_material_pbr_tangent.shaderbundle';

  // The slots of the simpler shader: on the web, those of its WebGPU bundle,
  // which reads no light grid.
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
    if (!_kIsWeb) ...[
      RenderContext3D.lightGridBlock,
      RenderContext3D.lightGridSampler,
    ],
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
    RenderContext3D.lightGridBlock,
    RenderContext3D.lightGridSampler,
  ];

  Shader? _tangentVertexShader;

  @override
  Shader vertexShaderFor(VertexLayout layout) {
    if (!usesSimpleShader &&
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
  Texture get albedoTexture => _albedoTexture;
  set albedoTexture(Texture value) =>
      _albedoTexture = noteChange(_albedoTexture, value);
  Texture _albedoTexture = albedoTexture ?? Texture.standard;

  /// UV tiling scale. Assigning a vector copies it; changing it in place
  /// counts as a change ([version]).
  Vector2 get uvScale => _uvScale;
  set uvScale(Vector2 value) => _uvScale.setFrom(value);
  final NotifyingVector2 _uvScale = NotifyingVector2.copy(
    uvScale ?? Vector2.all(1),
  );

  /// UV translation offset. Assigning a vector copies it; changing it in
  /// place counts as a change ([version]).
  Vector2 get uvOffset => _uvOffset;
  set uvOffset(Vector2 value) => _uvOffset.setFrom(value);
  final NotifyingVector2 _uvOffset = NotifyingVector2.copy(
    uvOffset ?? Vector2.zero(),
  );

  // The UV transform the version was last raised for: the vectors notify
  // every write, also of the values they hold.
  final Vector4 _lastUv = Vector4.zero();

  void _onUvChanged() {
    final scale = _uvScale;
    final offset = _uvOffset;
    final last = _lastUv;
    if (scale.x != last.x ||
        scale.y != last.y ||
        offset.x != last.z ||
        offset.y != last.w) {
      last.setValues(scale.x, scale.y, offset.x, offset.y);
      markChanged();
    }
  }

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

    if (!usesSimpleShader) {
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
