part of 'async_model_loader_3d.dart';

/// Flat median-split Bounding Volume Hierarchy buffers prepared on a background
/// isolate by [AsyncModelLoader3D.buildSurfaceBvhsInIsolate].
class PreparedSurfaceBvh3D({
  required final int surfaceIndex,
  required final int nodeCount,
  required final int triangleCount,
  required final Float32List bounds,
  required final Int32List leftOrFirst,
  required final Int32List rightChild,
  required final Int32List counts,
  required final Int32List triangles,
});

class _BvhSurfaceInput({
  required final int surfaceIndex,
  required final int stride,
  required final int posOffset,
  required final bool wideIndices,
  required final TransferableTypedData vertices,
  required final TransferableTypedData indices,
});

class _BvhSurfaceOutput({
  required final int surfaceIndex,
  required final int nodeCount,
  required final int triangleCount,
  required final TransferableTypedData bounds,
  required final TransferableTypedData leftOrFirst,
  required final TransferableTypedData rightChild,
  required final TransferableTypedData counts,
  required final TransferableTypedData triangles,
});

class _ObjTriCorner(final int v, final int vt, final int vn);

class _PreparedObjSurface({
  required final TransferableTypedData vertices,
  required final TransferableTypedData indices,
  required final bool wideIndices,
  required final List<double>? kdRgb,
});

class _PreparedObj(final List<_PreparedObjSurface> surfaces);

class _PreparedSampler({
  required final int? magFilter,
  required final int? minFilter,
  required final int wrapS,
  required final int wrapT,
}) {
  factory _PreparedSampler.fromMap(Map<String, Object?> map) {
    return _PreparedSampler(
      magFilter: (map['magFilter'] as num?)?.toInt(),
      minFilter: (map['minFilter'] as num?)?.toInt(),
      wrapS: (map['wrapS'] as num?)?.toInt() ?? 10497,
      wrapT: (map['wrapT'] as num?)?.toInt() ?? 10497,
    );
  }

  TextureSampler toFlameSampler() {
    TextureWrap wrapOf(int code) => switch (code) {
      33071 => TextureWrap.clamp,
      33648 => TextureWrap.mirror,
      _ => TextureWrap.repeat,
    };
    final mag = magFilter == 9728
        ? TextureFilter.nearest
        : TextureFilter.linear;
    final min = switch (minFilter) {
      9728 || 9984 || 9986 => TextureFilter.nearest,
      _ => TextureFilter.linear,
    };
    final mip = switch (minFilter) {
      9984 || 9985 => TextureFilter.nearest,
      _ => TextureFilter.linear,
    };
    return TextureSampler(
      minFilter: min,
      magFilter: mag,
      mipFilter: mip,
      wrapU: wrapOf(wrapS),
      wrapV: wrapOf(wrapT),
    );
  }
}

class _PreparedMaterial({
  required final ui.Color baseColor,
  required final int? baseColorTex,
  required final double metallic,
  required final double roughness,
  required final int? metallicRoughnessTex,
  required final int? normalTex,
  required final double normalScale,
  required final int? occlusionTex,
  required final double occlusionStrength,
  required final int? emissiveTex,
  required final ui.Color emissiveColor,
  required final double emissiveStrength,
  required final double uvOffsetX,
  required final double uvOffsetY,
  required final double uvScaleX,
  required final double uvScaleY,
  required final String alphaMode,
  required final double alphaCutoff,
  required final bool doubleSided,
  required final bool isUnlit,
}) {
  factory _PreparedMaterial.fromMap(Map<String, Object?> map) {
    final pbr = map['pbrMetallicRoughness'] as Map<String, Object?>?;
    final bcf = (pbr?['baseColorFactor'] as List<Object?>?)
        ?.map((e) => (e! as num).toDouble())
        .toList(growable: false);
    final baseColor = bcf != null && bcf.length >= 4
        ? ui.Color.fromARGB(
            (bcf[3].clamp(0.0, 1.0) * 255).round(),
            (bcf[0].clamp(0.0, 1.0) * 255).round(),
            (bcf[1].clamp(0.0, 1.0) * 255).round(),
            (bcf[2].clamp(0.0, 1.0) * 255).round(),
          )
        : const ui.Color(0xFFFFFFFF);

    int? texIdxOf(Object? info) =>
        info is Map<String, Object?> ? (info['index'] as num?)?.toInt() : null;

    final baseTexInfo = pbr?['baseColorTexture'];
    var uvOffX = 0.0;
    var uvOffY = 0.0;
    var uvSclX = 1.0;
    var uvSclY = 1.0;
    if (baseTexInfo is Map<String, Object?>) {
      final texExts = baseTexInfo['extensions'];
      if (texExts is Map<String, Object?>) {
        final kt = texExts['KHR_texture_transform'];
        if (kt is Map<String, Object?>) {
          final off = kt['offset'] as List<Object?>?;
          if (off != null && off.length >= 2) {
            uvOffX = (off[0]! as num).toDouble();
            uvOffY = (off[1]! as num).toDouble();
          }
          final scl = kt['scale'] as List<Object?>?;
          if (scl != null && scl.length >= 2) {
            uvSclX = (scl[0]! as num).toDouble();
            uvSclY = (scl[1]! as num).toDouble();
          }
        }
      }
    }

    final normInfo = map['normalTexture'] as Map<String, Object?>?;
    final occInfo = map['occlusionTexture'] as Map<String, Object?>?;
    final emiFactor = (map['emissiveFactor'] as List<Object?>?)
        ?.map((e) => (e! as num).toDouble())
        .toList(growable: false);
    final emiColor = emiFactor != null && emiFactor.length >= 3
        ? ui.Color.fromARGB(
            255,
            (emiFactor[0].clamp(0.0, 1.0) * 255).round(),
            (emiFactor[1].clamp(0.0, 1.0) * 255).round(),
            (emiFactor[2].clamp(0.0, 1.0) * 255).round(),
          )
        : const ui.Color(0xFF000000);

    final exts = map['extensions'] as Map<String, Object?>?;
    final isUnlit = exts?['KHR_materials_unlit'] != null;
    final emiExt = exts?['KHR_materials_emissive_strength'];
    final emiStrength = emiExt is Map<String, Object?>
        ? (emiExt['emissiveStrength'] as num?)?.toDouble() ?? 1.0
        : 1.0;

    return _PreparedMaterial(
      baseColor: baseColor,
      baseColorTex: texIdxOf(baseTexInfo),
      metallic: (pbr?['metallicFactor'] as num?)?.toDouble() ?? 1.0,
      roughness: (pbr?['roughnessFactor'] as num?)?.toDouble() ?? 1.0,
      metallicRoughnessTex: texIdxOf(pbr?['metallicRoughnessTexture']),
      normalTex: texIdxOf(normInfo),
      normalScale: (normInfo?['scale'] as num?)?.toDouble() ?? 1.0,
      occlusionTex: texIdxOf(occInfo),
      occlusionStrength: (occInfo?['strength'] as num?)?.toDouble() ?? 1.0,
      emissiveTex: texIdxOf(map['emissiveTexture']),
      emissiveColor: emiColor,
      emissiveStrength: emiStrength,
      uvOffsetX: uvOffX,
      uvOffsetY: uvOffY,
      uvScaleX: uvSclX,
      uvScaleY: uvSclY,
      alphaMode: (map['alphaMode'] as String?) ?? 'OPAQUE',
      alphaCutoff: (map['alphaCutoff'] as num?)?.toDouble() ?? 0.5,
      doubleSided: (map['doubleSided'] as bool?) ?? false,
      isUnlit: isUnlit,
    );
  }
}

class _PreparedMorph({
  required final String name,
  required final TransferableTypedData posDeltas,
  required final TransferableTypedData? nrmDeltas,
});

class _PreparedSurface({
  required final TransferableTypedData vertices,
  required final TransferableTypedData indices,
  required final bool wideIndices,
  required final int? materialIndex,
  required final Map<int, int>? jointMap,
  required final List<_PreparedMorph> morphTargets,
  // The attributes kept in Surface.customAttributes: components per vertex
  // and values.
  required final Map<String, (int, TransferableTypedData)> customAttributes,
});

class _PreparedMesh(
  final List<_PreparedSurface> surfaces,
  final List<double>? weights,
);

class _PreparedSkin(final List<int> joints, final Float64List? ibms);

class _PreparedNode({
  required final int nodeIndex,
  required final int? parentNodeIndex,
  required final String? name,
  required final Float64List transformStorage,
  required final int? meshIndex,
  required final int? skinIndex,
  final List<double>? weights,
});

class _PreparedAnimChannel({
  required final int nodeIndex,
  required final String path,
  required final String interpolation,
  required final Float64List times,
  required final Float64List values,
});

class _PreparedAnimation(
  final String? name,
  final List<_PreparedAnimChannel> channels,
);

class _PreparedGlb({
  required final List<TransferableTypedData> images,
  required final List<_PreparedSampler> samplers,
  required final List<({int source, int? sampler})> textures,
  required final List<_PreparedMaterial> materials,
  required final List<_PreparedMesh> meshes,
  required final List<_PreparedSkin> skins,
  required final List<_PreparedNode> nodes,
  required final List<_PreparedAnimation> animations,
  final List<String> warnings = const [],
});
