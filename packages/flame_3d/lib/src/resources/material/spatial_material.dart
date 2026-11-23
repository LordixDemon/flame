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
  static const String _pbrBasicBundle =
      'packages/flame_3d/assets/shaders/spatial_material_pbr_basic.shaderbundle';
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
    RenderContext3D.spatialPassBlock,
    RenderContext3D.lightGridSampler,
  ];

  static const List<String> _pbrBasicFragmentSlots = [
    'albedoTexture',
    RenderContext3D.shadowMapSampler,
    'Material',
    RenderContext3D.spatialPassBlock,
    RenderContext3D.lightGridSampler,
  ];

  late final Shader? _defaultPbrFrag = _simpleShader ? null : fragmentShader;
  Shader? _basicFragmentShader;

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

  Shader _activeFragmentShader(RenderContext? context) {
    if (runtimeType == SpatialMaterial &&
        identical(fragmentShader, _defaultPbrFrag) &&
        context is RenderContext3D &&
        _normalTexture == null &&
        _metallicRoughnessTexture == null &&
        _occlusionTexture == null &&
        _emissiveTexture == null &&
        _lightmapTexture == null &&
        _environmentTexture == null &&
        _environmentProbe == null &&
        _clearcoat <= 1e-4 &&
        _transmission <= 1e-4 &&
        !_ditherFade &&
        context.renderDebugMode == RenderDebugMode3D.none &&
        (context.lightProbeGrid == null ||
            context.lightProbeGrid!.intensity <= 0) &&
        context.reflectionProbes.isEmpty) {
      return _basicFragmentShader ??= FragmentShader.fromAsset(
        _pbrBasicBundle,
        slots: _pbrBasicFragmentSlots,
      );
    }
    return fragmentShader;
  }

  @override
  Shader fragmentShaderFor(RenderContext3D context, VertexLayout layout) =>
      _activeFragmentShader(context);

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

  /// `true` when the material has neither an [environmentTexture] nor an
  /// [environmentProbe]: it then takes its environment from the
  /// `ReflectionProbeVolume3D` around each object it draws.
  @override
  bool get usesReflectionProbes =>
      environmentProbe == null && environmentTexture == null;

  int _appliedVersion = -1;
  Shader? _appliedFrag;
  int _appliedFragGen = -1;
  EnvironmentProbe3D? _appliedEnvProbe;
  double _appliedEnvProbeIntensity = -1.0;
  int _appliedProbeSlot = -1;
  double _appliedProbeWeight = -1.0;
  ReflectionProbeVolume3D? _appliedVolume;
  bool _appliedVolumeBoxProj = false;
  bool _appliedEnvHadRes = false;

  Shader? _cachedFrag;
  int _cachedFragGen = -1;
  int _albedoTexIdx = -1;
  int _normalTexIdx = -1;
  int _ormTexIdx = -1;
  int _occTexIdx = -1;
  int _emiTexIdx = -1;
  int _envTexIdx = -1;
  int _lmTexIdx = -1;
  UniformBlock? _cachedMatBlock;
  _SpatialMaterialOffsets? _cachedMatOff;

  @override
  bool get hasPassStableFragmentShader => runtimeType == SpatialMaterial;

  @override
  bool get cachesApply => runtimeType == SpatialMaterial;

  @override
  void invalidateApplyCache() {
    _appliedVersion = -1;
  }

  @override
  bool isApplyCacheValid(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    if (_appliedVersion != version ||
        !identical(_appliedFrag, fragmentShader) ||
        _appliedFragGen != fragmentShader.generation ||
        !identical(_appliedEnvProbe, _environmentProbe) ||
        (_environmentProbe?.intensity ?? -1.0) != _appliedEnvProbeIntensity) {
      return false;
    }
    if (context is RenderContext3D) {
      final vol = context.reflectionProbe;
      if (_appliedProbeSlot != context.activeProbeSlot ||
          _appliedProbeWeight != context.activeProbeWeight ||
          !identical(_appliedVolume, vol) ||
          (vol != null && _appliedVolumeBoxProj != vol.boxProjection)) {
        return false;
      }
      if (!usesSimpleShader) {
        final envTex =
            environmentTexture ??
            (vol?.probe ?? _environmentProbe)?.reflectionTexture;
        if (envTex != null && envTex.hasResource != _appliedEnvHadRes) {
          return false;
        }
      }
    }
    return true;
  }

  @override
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    _appliedVersion = version;
    _appliedFrag = fragmentShader;
    _appliedFragGen = fragmentShader.generation;
    _appliedEnvProbe = _environmentProbe;
    _appliedEnvProbeIntensity = _environmentProbe?.intensity ?? -1.0;
    if (context is RenderContext3D) {
      final vol = context.reflectionProbe;
      _appliedProbeSlot = context.activeProbeSlot;
      _appliedProbeWeight = context.activeProbeWeight;
      _appliedVolume = vol;
      _appliedVolumeBoxProj = vol?.boxProjection ?? false;
      final envTex =
          environmentTexture ??
          (vol?.probe ?? _environmentProbe)?.reflectionTexture;
      _appliedEnvHadRes = envTex?.hasResource ?? false;
    }
  }

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

    final frag = _activeFragmentShader(context);
    frag.resource;
    if (!identical(_cachedFrag, frag) || _cachedFragGen != frag.generation) {
      _cachedFrag = frag;
      _cachedFragGen = frag.generation;
      _albedoTexIdx = frag.samplerIndexOf('albedoTexture');
      _normalTexIdx = frag.samplerIndexOf('normalTexture');
      _ormTexIdx = frag.samplerIndexOf('metallicRoughnessTexture');
      _occTexIdx = frag.samplerIndexOf('occlusionTexture');
      _emiTexIdx = frag.samplerIndexOf('emissiveTexture');
      _envTexIdx = frag.samplerIndexOf('environmentTexture');
      _lmTexIdx = frag.samplerIndexOf('lightmapTexture');
      final matIdx = frag.blockIndexOf('Material');
      if (matIdx >= 0) {
        final blk = frag.blockAt(matIdx);
        _cachedMatBlock = blk;
        _cachedMatOff =
            (blk.cachedWriterOffsets as _SpatialMaterialOffsets?) ??
            (blk.cachedWriterOffsets = _SpatialMaterialOffsets(blk));
      } else {
        _cachedMatBlock = null;
        _cachedMatOff = null;
      }
    }

    final matBlock = _cachedMatBlock;
    if (matBlock == null) {
      if (_albedoTexIdx >= 0) {
        frag.setTextureAt(_albedoTexIdx, albedoTexture);
      }
      if (_normalTexIdx >= 0) {
        frag.setTextureAt(_normalTexIdx, normTex ?? Texture.standard);
      }
      if (_ormTexIdx >= 0) {
        frag.setTextureAt(_ormTexIdx, ormTex ?? Texture.standard);
      }
      if (_occTexIdx >= 0) {
        frag.setTextureAt(_occTexIdx, occTex ?? Texture.standard);
      }
      if (_emiTexIdx >= 0) {
        frag.setTextureAt(_emiTexIdx, emiTex ?? Texture.standard);
      }
      if (_envTexIdx >= 0) {
        frag.setTextureAt(_envTexIdx, envTex ?? Texture.standard);
      }
      return;
    }

    final off = _cachedMatOff!;
    final simple = usesSimpleShader;
    // If only the reflection probe weight changed since the last apply, update
    // just the two weight-dependent scalar floats in place.
    if (_appliedVersion == version &&
        identical(_appliedFrag, frag) &&
        _appliedFragGen == frag.generation &&
        identical(_appliedEnvProbe, _environmentProbe) &&
        (_environmentProbe?.intensity ?? -1.0) == _appliedEnvProbeIntensity &&
        identical(_appliedVolume, volume) &&
        (volume == null || _appliedVolumeBoxProj == volume.boxProjection) &&
        (simple || envTex == null || envTex.hasResource == _appliedEnvHadRes)) {
      if (off._flags >= 0) {
        matBlock.writeFloatAt(
          off._flags + 3,
          envTex != null ? environmentIntensity * volumeWeight : 0.0,
        );
      }
      if (off._shCoeffs >= 0 && probe != null && probe.intensity > 0) {
        matBlock.writeFloatAt(
          off._shCoeffs + 3,
          probe.intensity * volumeWeight / math.pi,
        );
      }
      return;
    }

    if (_albedoTexIdx >= 0) {
      frag.setTextureAt(_albedoTexIdx, albedoTexture);
    }
    if (_normalTexIdx >= 0) {
      frag.setTextureAt(_normalTexIdx, normTex ?? Texture.standard);
    }
    if (_ormTexIdx >= 0) {
      frag.setTextureAt(_ormTexIdx, ormTex ?? Texture.standard);
    }
    if (_occTexIdx >= 0) {
      frag.setTextureAt(_occTexIdx, occTex ?? Texture.standard);
    }
    if (_emiTexIdx >= 0) {
      frag.setTextureAt(_emiTexIdx, emiTex ?? Texture.standard);
    }
    if (_envTexIdx >= 0) {
      frag.setTextureAt(_envTexIdx, envTex ?? Texture.standard);
    }

    if (off._albedoColor >= 0) {
      matBlock.writeColorAt(off._albedoColor, albedoColor);
    }
    if (off._emissiveColor >= 0) {
      matBlock.writeVec4ValuesAt(
        off._emissiveColor,
        emissiveColor.r * emissiveStrength,
        emissiveColor.g * emissiveStrength,
        emissiveColor.b * emissiveStrength,
        alphaCutoff,
      );
    }
    if (off._uvTransform >= 0) {
      matBlock.writeVec4ValuesAt(
        off._uvTransform,
        uvScale.x,
        uvScale.y,
        uvOffset.x,
        uvOffset.y,
      );
    }
    if (off._params >= 0) {
      matBlock.writeVec4ValuesAt(
        off._params,
        metallic,
        roughness,
        normalScale,
        occlusionStrength,
      );
    }
    if (off._flags >= 0) {
      matBlock.writeVec4ValuesAt(
        off._flags,
        normTex != null ? 1.0 : 0.0,
        ormTex != null ? 1.0 : 0.0,
        occTex != null ? 1.0 : 0.0,
        envTex != null ? environmentIntensity * volumeWeight : 0.0,
      );
    }
    if (off._flags2 >= 0) {
      matBlock.writeVec4ValuesAt(
        off._flags2,
        doubleSided ? 1.0 : 0.0,
        ditherFade ? 1.0 : 0.0,
        premul ? 1.0 : 0.0,
        emiTex != null ? 1.0 : 0.0,
      );
    }

    if (!usesSimpleShader) {
      var maxMip = 0.0;
      if (envTex != null) {
        envTex.resource;
        maxMip = math.max(0, envTex.mipLevelCount - 1).toDouble();
      }
      if (_lmTexIdx >= 0) {
        frag.setTextureAt(_lmTexIdx, lmTex ?? Texture.standard);
      }
      if (off._pbrExt >= 0) {
        matBlock.writeVec4ValuesAt(
          off._pbrExt,
          clearcoat,
          clearcoatRoughness,
          transmission,
          ior,
        );
      }
      if (off._iblParams >= 0) {
        matBlock.writeVec4ValuesAt(
          off._iblParams,
          lmTex != null ? 1.0 : 0.0,
          lightmapIntensity,
          maxMip,
          envTex != null ? 1.0 : 0.0,
        );
      }
      if (volume != null) {
        final box = volume.worldBounds;
        final center = volume.worldCenter;
        if (off._probeBoxMin >= 0) {
          matBlock.writeVec4ValuesAt(
            off._probeBoxMin,
            box.min.x,
            box.min.y,
            box.min.z,
            0,
          );
        }
        if (off._probeBoxMax >= 0) {
          matBlock.writeVec4ValuesAt(
            off._probeBoxMax,
            box.max.x,
            box.max.y,
            box.max.z,
            0,
          );
        }
        if (off._probeCenter >= 0) {
          matBlock.writeVec4ValuesAt(
            off._probeCenter,
            center.x,
            center.y,
            center.z,
            volume.boxProjection ? 1.0 : 0.0,
          );
        }
      } else {
        if (off._probeBoxMin >= 0) {
          matBlock.writeVec4ValuesAt(off._probeBoxMin, 0, 0, 0, 0);
        }
        if (off._probeBoxMax >= 0) {
          matBlock.writeVec4ValuesAt(off._probeBoxMax, 0, 0, 0, 0);
        }
        if (off._probeCenter >= 0) {
          matBlock.writeVec4ValuesAt(off._probeCenter, 0, 0, 0, 0);
        }
      }
    }

    // The coefficients give irradiance: like the direct lights, the diffuse
    // light is the irradiance times kD * base / pi.
    if (off._shCoeffs >= 0) {
      if (probe != null && probe.intensity > 0) {
        final diffuseScale = probe.intensity * volumeWeight / math.pi;
        for (var i = 0; i < 9; i++) {
          final c = probe.shCoefficients[i];
          matBlock.writeVec4ValuesAt(
            off._shCoeffs + i * 4,
            c.x,
            c.y,
            c.z,
            i == 0 ? diffuseScale : 0.0,
          );
        }
      } else {
        matBlock.writeVec4ValuesAt(off._shCoeffs, 0, 0, 0, 0);
      }
    }
  }
}

class _SpatialMaterialOffsets(final UniformBlock _b) {
  late final int _albedoColor = _b.resolveOffset('albedoColor');
  late final int _emissiveColor = _b.resolveOffset('emissiveColor');
  late final int _uvTransform = _b.resolveOffset('uvTransform');
  late final int _params = _b.resolveOffset('params');
  late final int _flags = _b.resolveOffset('flags');
  late final int _flags2 = _b.resolveOffset('flags2');
  late final int _pbrExt = _b.resolveOffset('pbrExt');
  late final int _iblParams = _b.resolveOffset('iblParams');
  late final int _probeBoxMin = _b.resolveOffset('probeBoxMin');
  late final int _probeBoxMax = _b.resolveOffset('probeBoxMax');
  late final int _probeCenter = _b.resolveOffset('probeCenter');
  late final int _shCoeffs = _b.resolveOffset('shCoeffs');
}
