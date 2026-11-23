import 'dart:typed_data';
import 'dart:ui' as ui show Color, Image, instantiateImageCodec;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart' as flame_gfx;
import 'package:flame_3d/resources.dart' as flame_3d;
import 'package:flame_3d/src/parser/gltf/gltf_buffers.dart';
import 'package:flame_3d/src/parser/gltf/gltf_enums.dart';
import 'package:flame_3d/src/parser/gltf/gltf_extensions.dart';
import 'package:flame_3d/src/parser/gltf/gltf_node.dart';
import 'package:flame_3d/src/parser/gltf/gltf_root.dart';
import 'package:flame_3d/src/parser/gltf/gltf_warnings.dart';

// cSpell:ignore TEXCOORD
// (used in GLTF as the key for texture coordinate attributes)

/// Image data used to create a texture.
class Image({
  required super.root,

  /// The URI (or IRI) of the image.
  ///
  /// Relative paths are relative to the current glTF asset.
  /// Instead of referencing an external file, this field **MAY** contain a
  /// `data:`-URI.
  /// This field **MUST NOT** be defined when `bufferView` is defined.
  required final String? uri,

  /// The image's media type.
  ///
  /// This field **MUST** be defined when `bufferView` is defined.
  required final MimeType? mimeType,

  /// The reference to the bufferView that contains the image.
  /// This field **MUST NOT** be defined when `uri` is defined.
  required final GltfRef<BufferView>? bufferView,
}) extends GltfNode with GltfNodeWithData<flame_3d.ImageTexture> {
  Image.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        uri: Parser.string(map, 'uri'),
        mimeType: MimeType.parse(map, 'mimeType'),
        bufferView: Parser.ref(root, map, 'bufferView'),
      );

  Future<Uint8List> data() async {
    final uri = this.uri;
    if (uri != null) {
      return await root.readChunkFrom(uri);
    } else {
      final bufferView = this.bufferView?.get();
      if (bufferView == null) {
        throw Exception('Either `uri` or `bufferView` must be defined');
      }
      return bufferView.data();
    }
  }

  Future<ui.Image> parseDartImage() async {
    final bytes = await data();
    final codec = await ui.instantiateImageCodec(bytes);
    final frameInfo = await codec.getNextFrame();
    return frameInfo.image;
  }

  @override
  Future<flame_3d.ImageTexture> loadData() async {
    return await flame_3d.ImageTexture.create(await parseDartImage());
  }

  flame_3d.ImageTexture toFlameTexture() {
    return getData();
  }
}

/// Texture sampler properties for filtering and wrapping modes.
class Sampler({
  required super.root,
  required final MagFilter magFilter,
  required final MinFilter minFilter,
  required final WrapMode wrapS,
  required final WrapMode wrapT,
}) extends GltfNode {
  Sampler.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        magFilter: MagFilter.parse(map, 'magFilter') ?? MagFilter.linear,
        minFilter:
            MinFilter.parse(map, 'minFilter') ?? MinFilter.nearestMipmapLinear,
        wrapS: WrapMode.parse(map, 'wrapS') ?? WrapMode.repeat,
        wrapT: WrapMode.parse(map, 'wrapT') ?? WrapMode.repeat,
      );

  flame_3d.TextureSampler toFlameSampler() {
    final mag = switch (magFilter) {
      MagFilter.nearest => flame_3d.TextureFilter.nearest,
      MagFilter.linear => flame_3d.TextureFilter.linear,
    };
    final (min, mip) = switch (minFilter) {
      MinFilter.nearest => (
        flame_3d.TextureFilter.nearest,
        flame_3d.TextureFilter.nearest,
      ),
      MinFilter.linear => (
        flame_3d.TextureFilter.linear,
        flame_3d.TextureFilter.nearest,
      ),
      MinFilter.nearestMipmapNearest => (
        flame_3d.TextureFilter.nearest,
        flame_3d.TextureFilter.nearest,
      ),
      MinFilter.linearMipmapNearest => (
        flame_3d.TextureFilter.linear,
        flame_3d.TextureFilter.nearest,
      ),
      MinFilter.nearestMipmapLinear => (
        flame_3d.TextureFilter.nearest,
        flame_3d.TextureFilter.linear,
      ),
      MinFilter.linearMipmapLinear => (
        flame_3d.TextureFilter.linear,
        flame_3d.TextureFilter.linear,
      ),
    };
    flame_3d.TextureWrap mapWrap(WrapMode w) => switch (w) {
      WrapMode.clampToEdge => flame_3d.TextureWrap.clamp,
      WrapMode.mirroredRepeat => flame_3d.TextureWrap.mirror,
      WrapMode.repeat => flame_3d.TextureWrap.repeat,
    };
    return flame_3d.TextureSampler(
      minFilter: min,
      magFilter: mag,
      mipFilter: mip,
      wrapU: mapWrap(wrapS),
      wrapV: mapWrap(wrapT),
    );
  }
}

class Texture({
  required super.root,
  required final TextureFormat format,
  required final TextureFormat internalFormat,
  required final GltfRef<Sampler>? sampler,
  required final GltfRef<Image> source,
  required final TextureTarget target,
  required final TextureType type,
}) extends GltfNode {
  Texture.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        format: TextureFormat.parse(map, 'format') ?? TextureFormat.rgba,
        internalFormat:
            TextureFormat.parse(map, 'internalFormat') ?? TextureFormat.rgba,
        sampler: Parser.ref<Sampler>(root, map, 'sampler'),
        source: Parser.ref<Image>(root, map, 'source')!,
        target: TextureTarget.parse(map, 'target') ?? TextureTarget.texture2d,
        type: TextureType.parse(map, 'type') ?? TextureType.unsignedByte,
      );

  flame_3d.Texture toFlameTexture() {
    final imgTex = source.get().toFlameTexture();
    final flameSampler = sampler?.get().toFlameSampler();
    if (flameSampler == null) {
      return imgTex;
    }
    return flame_3d.ImageTexture(
      imgTex.sourceData,
      width: imgTex.width,
      height: imgTex.height,
      sampler: flameSampler,
      mipmaps: imgTex.mipmaps,
      gpuTexture: imgTex.gpuTexture,
    );
  }
}

/// Reference to a texture.
class TextureInfo({
  required super.root,

  /// The reference to the texture.
  required final GltfRef<Texture> index,

  /// This integer value is used to construct a string in the format
  /// `TEXCOORD_<set index>`, which is a reference to a key in
  /// `mesh.primitives.attributes`
  /// (e.g. a value of `0` corresponds to `TEXCOORD_0`).
  ///
  /// A mesh primitive **MUST** have the corresponding texture coordinate
  /// attributes for the material to be applicable to it.
  final int? texCoord,
  final Map<String, Object?>? extensions,
  final Object? extras,
}) extends GltfNode {
  TextureInfo.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        index: Parser.ref(root, map, 'index')!,
        texCoord: Parser.integer(map, 'texCoord'),
        extensions: Parser.extensions(map),
        extras: Parser.extras(map),
      );

  /// Parsed `KHR_texture_transform` extension if present on this texture slot.
  KhrTextureTransform? get textureTransform {
    final ext = extensions?['KHR_texture_transform'];
    if (ext is Map<String, Object?>) {
      return KhrTextureTransform.parse(ext);
    }
    return null;
  }

  flame_3d.Texture toFlameTexture() {
    return index.get().toFlameTexture();
  }
}

/// Material Normal Texture Info.
class NormalTextureInfo({
  required super.root,
  required super.index,
  required super.texCoord,

  /// The scalar parameter applied to each normal vector of the texture.
  ///
  /// This value scales the normal vector in X and Y directions using the
  /// formula:
  ///
  /// ```text
  ///   scaledNormal =  normalize((<sampled normal texture value> * 2.0 - 1.0)
  ///                       * vec3(<normal scale>, <normal scale>, 1.0))
  /// ```
  required final double scale,
  super.extensions,
  super.extras,
}) extends TextureInfo {
  NormalTextureInfo.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        index: Parser.ref(root, map, 'index')!,
        texCoord: Parser.integer(map, 'texCoord'),
        scale: Parser.float(map, 'scale') ?? 1.0,
        extensions: Parser.extensions(map),
        extras: Parser.extras(map),
      );
}

/// The occlusion texture.
class OcclusionTextureInfo({
  required super.root,
  required super.index,
  required super.texCoord,

  /// A scalar parameter controlling the amount of occlusion applied.
  ///
  /// A value of `0.0` means no occlusion. A value of `1.0` means full
  /// occlusion.
  ///
  /// This value affects the final occlusion value as:
  /// ```text
  ///   1.0 + strength * (<sampled occlusion texture value> - 1.0)
  /// ```
  required final double strength,
  super.extensions,
  super.extras,
}) extends TextureInfo {
  OcclusionTextureInfo.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        index: Parser.ref(root, map, 'index')!,
        texCoord: Parser.integer(map, 'texCoord'),
        strength: Parser.float(map, 'strength') ?? 1.0,
        extensions: Parser.extensions(map),
        extras: Parser.extras(map),
      );
}

/// A set of parameter values that are used to define the metallic-roughness
/// material model from Physically-Based Rendering (PBR) methodology.
class PBRMetallicRoughness({
  required super.root,
  required final Vector4? baseColorFactor,
  required final TextureInfo? baseColorTexture,
  required final double metallicFactor,
  required final double roughnessFactor,
  required final TextureInfo? metallicRoughnessTexture,
}) extends GltfNode {
  PBRMetallicRoughness.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        baseColorFactor: Parser.vector4(root, map, 'baseColorFactor'),
        baseColorTexture: Parser.object(
          root,
          map,
          'baseColorTexture',
          TextureInfo.parse,
        ),
        metallicFactor: Parser.float(map, 'metallicFactor') ?? 1.0,
        roughnessFactor: Parser.float(map, 'roughnessFactor') ?? 1.0,
        metallicRoughnessTexture: Parser.object(
          root,
          map,
          'metallicRoughnessTexture',
          TextureInfo.parse,
        ),
      );

  flame_3d.SpatialMaterial toFlameSpatialMaterial() {
    return flame_3d.SpatialMaterial(
      albedoColor: baseColorFactor?.toColor() ?? const ui.Color(0xFFFFFFFF),
      albedoTexture: baseColorTexture?.toFlameTexture(),
      metallic: metallicFactor,
      roughness: roughnessFactor,
      metallicRoughnessTexture: metallicRoughnessTexture?.toFlameTexture(),
    );
  }
}

extension ToColorVector4 on Vector4 {
  ui.Color toColor() {
    return ui.Color.fromARGB(
      (a.clamp(0.0, 1.0) * 255).round(),
      (r.clamp(0.0, 1.0) * 255).round(),
      (g.clamp(0.0, 1.0) * 255).round(),
      (b.clamp(0.0, 1.0) * 255).round(),
    );
  }
}

/// The material appearance of a primitive.
class Material({
  required super.root,
  required final String? name,
  required final PBRMetallicRoughness? pbrMetallicRoughness,
  required final NormalTextureInfo? normalTexture,
  required final OcclusionTextureInfo? occlusionTexture,
  required final TextureInfo? emissiveTexture,
  required final Vector3 emissiveFactor,
  required final AlphaMode alphaMode,
  required final double alphaCutoff,
  required final bool doubleSided,
  final Map<String, Object?>? extensions,
  final Object? extras,
}) extends GltfNode {
  Material.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        name: Parser.string(map, 'name'),
        pbrMetallicRoughness: Parser.object(
          root,
          map,
          'pbrMetallicRoughness',
          PBRMetallicRoughness.parse,
        ),
        normalTexture: Parser.object(
          root,
          map,
          'normalTexture',
          NormalTextureInfo.parse,
        ),
        occlusionTexture: Parser.object(
          root,
          map,
          'occlusionTexture',
          OcclusionTextureInfo.parse,
        ),
        emissiveTexture: Parser.object(
          root,
          map,
          'emissiveTexture',
          TextureInfo.parse,
        ),
        emissiveFactor:
            Parser.vector3(root, map, 'emissiveFactor') ?? Vector3.all(0),
        alphaMode: AlphaMode.parse(map, 'alphaMode') ?? AlphaMode.opaque,
        alphaCutoff: Parser.float(map, 'alphaCutoff') ?? 0.5,
        doubleSided: Parser.boolean(map, 'doubleSided') ?? false,
        extensions: Parser.extensions(map),
        extras: Parser.extras(map),
      );

  /// Whether `KHR_materials_unlit` is enabled on this material.
  bool get isUnlit => extensions?['KHR_materials_unlit'] != null;

  /// Emissive multiplier from `KHR_materials_emissive_strength` (`1.0` by
  /// default).
  double get emissiveStrength {
    final ext = extensions?['KHR_materials_emissive_strength'];
    if (ext is Map<String, Object?>) {
      return Parser.float(ext, 'emissiveStrength') ?? 1.0;
    }
    return 1.0;
  }

  /// Reports, through [GltfWarnings], the texture settings the materials
  /// cannot honor: a second UV set, and `KHR_texture_transform` rotations or
  /// transforms that differ between textures (one offset and scale, the base
  /// color texture's, applies to every texture).
  void _reportUnsupportedTextureSettings() {
    final pbr = pbrMetallicRoughness;
    final slots = <TextureInfo?>[
      pbr?.baseColorTexture,
      pbr?.metallicRoughnessTexture,
      normalTexture,
      occlusionTexture,
      emissiveTexture,
    ];
    final base = pbr?.baseColorTexture?.textureTransform;
    for (final slot in slots) {
      if (slot == null) {
        continue;
      }
      final transform = slot.textureTransform;
      if ((slot.texCoord ?? 0) != 0 || (transform?.texCoord ?? 0) != 0) {
        GltfWarnings.report(
          'textures that use a second UV set (texCoord 1) read the first',
        );
      }
      if (transform != null && transform.rotation != 0.0) {
        GltfWarnings.report('KHR_texture_transform rotations are ignored');
      }
      final offset = transform?.offset ?? Vector2.zero();
      final scale = transform?.scale ?? Vector2.all(1);
      final baseOffset = base?.offset ?? Vector2.zero();
      final baseScale = base?.scale ?? Vector2.all(1);
      if (offset != baseOffset || scale != baseScale) {
        GltfWarnings.report(
          'KHR_texture_transform: the offset and scale of the base color '
          'texture apply to every texture of a material',
        );
      }
    }
  }

  flame_3d.Material toFlameMaterial() {
    final pbr = pbrMetallicRoughness;
    final cullMode = doubleSided
        ? flame_gfx.CullMode.none
        : flame_gfx.CullMode.backFace;
    _reportUnsupportedTextureSettings();

    if (isUnlit) {
      final unlit = flame_3d.UnlitMaterial(
        albedoColor:
            pbr?.baseColorFactor?.toColor() ?? const ui.Color(0xFFFFFFFF),
        albedoTexture: pbr?.baseColorTexture?.toFlameTexture(),
      );
      if (alphaMode == AlphaMode.mask) {
        GltfWarnings.report(
          'unlit materials with alphaMode MASK are drawn blended: '
          'UnlitMaterial has no alpha cutoff',
        );
      }
      unlit.renderState = switch (alphaMode) {
        AlphaMode.opaque => flame_gfx.RenderState.opaque.copyWith(
          cullMode: cullMode,
        ),
        AlphaMode.mask || AlphaMode.blend =>
          flame_gfx.RenderState.alphaBlend.copyWith(cullMode: cullMode),
      };
      return unlit;
    }

    final emissive = ui.Color.fromARGB(
      255,
      (emissiveFactor.x.clamp(0.0, 1.0) * 255).round(),
      (emissiveFactor.y.clamp(0.0, 1.0) * 255).round(),
      (emissiveFactor.z.clamp(0.0, 1.0) * 255).round(),
    );
    final translucent = alphaMode == AlphaMode.blend;
    final cutoff = alphaMode == AlphaMode.mask ? alphaCutoff : 0.0;
    final uvTransform = pbr?.baseColorTexture?.textureTransform;

    final mat = flame_3d.SpatialMaterial(
      albedoColor:
          pbr?.baseColorFactor?.toColor() ?? const ui.Color(0xFFFFFFFF),
      albedoTexture: pbr?.baseColorTexture?.toFlameTexture(),
      metallic: pbr?.metallicFactor ?? 1.0,
      roughness: pbr?.roughnessFactor ?? 1.0,
      metallicRoughnessTexture: pbr?.metallicRoughnessTexture?.toFlameTexture(),
      normalTexture: normalTexture?.toFlameTexture(),
      normalScale: normalTexture?.scale ?? 1.0,
      occlusionTexture: occlusionTexture?.toFlameTexture(),
      occlusionStrength: occlusionTexture?.strength ?? 1.0,
      emissiveTexture: emissiveTexture?.toFlameTexture(),
      emissiveColor: emissive,
      emissiveStrength: emissiveStrength,
      uvOffset: uvTransform?.offset.clone(),
      uvScale: uvTransform?.scale.clone(),
      alphaCutoff: cutoff,
      doubleSided: doubleSided,
      translucent: translucent,
    );
    mat.renderState = mat.renderState.copyWith(cullMode: cullMode);
    return mat;
  }
}
