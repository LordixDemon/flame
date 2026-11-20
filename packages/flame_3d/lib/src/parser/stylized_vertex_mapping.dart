import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/parser/gltf/gltf_warnings.dart';
import 'package:meta/meta.dart';

/// {@template attribute_channel}
/// One float per vertex for an input of [StylizedVertexMapping]: a
/// [component] of the custom attribute named [attribute] of a surface (see
/// [Surface.customAttributes]), or a [value] for every vertex.
/// {@endtemplate}
@immutable
class const AttributeChannel._(
  /// The name of the custom attribute, as the glTF file names it (`_WIND`,
  /// `TEXCOORD_1`), or `null` for a [value].
  final String? attribute,

  /// The component of the attribute: `0` (x) to `3` (w).
  final int component,

  /// The value of every vertex, when [attribute] is `null`.
  final double value,
) {
  /// {@macro attribute_channel}
  ///
  /// Component [component] (`0` to `3`) of the custom attribute [attribute].
  const AttributeChannel(String attribute, [int component = 0])
    : this._(attribute, component, 0);

  /// The same [value] for every vertex.
  const AttributeChannel.constant(double value) : this._(null, 0, value);

  @override
  String toString() => attribute == null
      ? '$value'
      : '$attribute${component == 0 ? '' : '.${'xyzw'[component]}'}';
}

/// {@template stylized_vertex_mapping}
/// Where the per-vertex values of [StylizedMaterial]'s layout come from when
/// a surface in the standard layout (a parsed glTF model's) is converted to
/// it: the position, normal, vertex color, joints and weights of the surface,
/// and each mask, the occlusion and the wind from a [AttributeChannel] of its
/// custom attributes ([Surface.customAttributes], the glTF readers keep a
/// primitive's application attributes, `_NAME`, there).
///
/// An input without a channel, or whose attribute a surface lacks, takes the
/// default of [StylizedMaterial.buildSurface]: no tint, accent or emissive
/// mask, no gloss, unoccluded, no sway, phase `0`, no flutter. (The standard
/// layout drawn as it is is tinted everywhere: `tint:
/// AttributeChannel.constant(1)` keeps that.)
///
/// ```dart
/// final model = await ModelParser.parse('hero.glb');
/// const StylizedVertexMapping(
///   tint: AttributeChannel('_MASKS', 0),
///   accent: AttributeChannel('_MASKS', 1),
///   emissive: AttributeChannel('_MASKS', 2),
///   sway: AttributeChannel('_WIND'),
/// ).convertModel(model);
/// world.add(ModelComponent(model: model));
/// ```
/// {@endtemplate}
@immutable
class const StylizedVertexMapping({
  /// The tint mask: where the instance color tints the vertex.
  final AttributeChannel? tint,

  /// The accent mask.
  final AttributeChannel? accent,

  /// The emissive mask.
  final AttributeChannel? emissive,

  /// The gloss.
  final AttributeChannel? gloss,

  /// The ambient occlusion, `1` unoccluded.
  final AttributeChannel? occlusion,

  /// The sway weight of the wind.
  final AttributeChannel? sway,

  /// The phase of the wind, in turns.
  final AttributeChannel? windPhase,

  /// The flutter weight of the wind.
  final AttributeChannel? windFlutter,

  /// The custom attribute holding the texture coordinates of the base color
  /// texture (`TEXCOORD_1`, for instance), or `null` (the default) for the
  /// surface's own (`vertexTexCoord`, the glTF `TEXCOORD_0`).
  final String? texCoord,
}) {
  /// The inputs and their channels, in the order of [StylizedMaterial]'s
  /// layout.
  List<(String, AttributeChannel?)> get _channels => [
    ('tint', tint),
    ('accent', accent),
    ('emissive', emissive),
    ('gloss', gloss),
    ('occlusion', occlusion),
    ('sway', sway),
    ('windPhase', windPhase),
    ('windFlutter', windFlutter),
  ];

  /// Converts [source], a surface whose layout has a position (such as the
  /// standard layout of the glTF readers), into a surface in
  /// [StylizedMaterial]'s layout drawn with [material]: skinned
  /// ([StylizedMaterial.skinnedVertexLayout]) when its vertices have joints
  /// with weights, textured ([StylizedMaterial.texturedVertexLayout]) when
  /// [material] has a base color texture, its texture coordinates scaled by
  /// [uvScale] and moved by [uvOffset] (`uv * uvScale + uvOffset`, as
  /// `SpatialMaterial` applies them).
  ///
  /// The new surface keeps the indices, topology, joint map, morph targets,
  /// custom attributes and bounds of [source], and its rest vertices (those
  /// before morph weights). Inputs whose attribute [source] lacks (or holds
  /// for fewer vertices) take their default and are added to [missing] (as
  /// `input (attribute)`) when given.
  Surface convertSurface(
    Surface source, {
    required StylizedMaterial material,
    Vector2? uvScale,
    Vector2? uvOffset,
    Set<String>? missing,
  }) {
    final layout = source.layout;
    final position = layout.offsetOf(VertexLayout.positionAttribute);
    if (position == null) {
      throw ArgumentError.value(
        layout,
        'source',
        'A surface needs positions to be converted',
      );
    }
    final normal = layout.offsetOf('vertexNormal');
    final color = layout.attribute('vertexColor')?.components ?? 0;
    final colorAt = layout.offsetOf('vertexColor');
    final joints = layout.attribute(StylizedMaterial.jointsAttribute);
    final weights = layout.attribute(StylizedMaterial.weightsAttribute);
    final stride = layout.strideInFloats;
    final count = source.vertexCount;
    final data = source.restVertexData;

    final jointsAt = joints?.components == 4
        ? layout.offsetOf(StylizedMaterial.jointsAttribute)
        : null;
    final weightsAt = weights?.components == 4
        ? layout.offsetOf(StylizedMaterial.weightsAttribute)
        : null;
    var skinned = false;
    if (jointsAt != null && weightsAt != null) {
      for (var v = 0; !skinned && v < count; v++) {
        for (var k = 0; k < 4; k++) {
          if (data[v * stride + weightsAt + k] != 0) {
            skinned = true;
            break;
          }
        }
      }
    }

    // The texture coordinates: a custom attribute, or the surface's own.
    final textured = material.baseColorTexture != null;
    Float32List? uvValues;
    var uvComponents = 0;
    var uvAt = 0;
    if (textured) {
      final named = texCoord;
      if (named != null) {
        final attribute = source.customAttributes[named];
        if (attribute == null ||
            attribute.components < 2 ||
            attribute.vertexCount < count) {
          missing?.add('texCoord ($named)');
        } else {
          uvValues = attribute.values;
          uvComponents = attribute.components;
        }
      } else {
        final own = layout.offsetOf(StylizedMaterial.texCoordAttribute);
        if (own == null) {
          missing?.add('texCoord (${StylizedMaterial.texCoordAttribute})');
        } else {
          uvValues = data;
          uvComponents = stride;
          uvAt = own;
        }
      }
    }
    final scaleU = uvScale?.x ?? 1.0;
    final scaleV = uvScale?.y ?? 1.0;
    final offsetU = uvOffset?.x ?? 0.0;
    final offsetV = uvOffset?.y ?? 0.0;

    // Each input's values, or its constant.
    final channels = _channels;
    final sources = List<Float32List?>.filled(channels.length, null);
    final strides = List<int>.filled(channels.length, 0);
    final picks = List<int>.filled(channels.length, 0);
    final constants = List<double>.of(_defaults);
    for (final (i, (input, channel)) in channels.indexed) {
      if (channel == null) {
        continue;
      }
      final name = channel.attribute;
      if (name == null) {
        constants[i] = channel.value;
        continue;
      }
      final attribute = source.customAttributes[name];
      if (attribute == null ||
          channel.component >= attribute.components ||
          attribute.vertexCount < count) {
        missing?.add('$input ($channel)');
        continue;
      }
      sources[i] = attribute.values;
      strides[i] = attribute.components;
      picks[i] = channel.component;
    }

    final target = switch ((skinned, textured)) {
      (false, false) => StylizedMaterial.vertexLayout,
      (true, false) => StylizedMaterial.skinnedVertexLayout,
      (false, true) => StylizedMaterial.texturedVertexLayout,
      (true, true) => StylizedMaterial.texturedSkinnedVertexLayout,
    };
    final out = target.strideInFloats;
    final skinAt = textured ? 20 : 18;
    final vertices = Float32List(count * out);
    for (var v = 0; v < count; v++) {
      final o = v * out;
      final s = v * stride;
      vertices
        ..[o] = data[s + position]
        ..[o + 1] = data[s + position + 1]
        ..[o + 2] = data[s + position + 2];
      if (normal != null) {
        vertices
          ..[o + 3] = data[s + normal]
          ..[o + 4] = data[s + normal + 1]
          ..[o + 5] = data[s + normal + 2];
      } else {
        vertices[o + 4] = 1;
      }
      for (var c = 0; c < 4; c++) {
        vertices[o + 6 + c] = colorAt != null && c < color
            ? data[s + colorAt + c]
            : 1;
      }
      // The masks (10 to 13), the occlusion (14) and the wind (15 to 17), in
      // the order of the channels.
      for (var i = 0; i < channels.length; i++) {
        final values = sources[i];
        vertices[o + 10 + i] = values == null
            ? constants[i]
            : values[v * strides[i] + picks[i]];
      }
      if (textured) {
        final values = uvValues;
        if (values != null) {
          final u = v * uvComponents + uvAt;
          vertices
            ..[o + 18] = values[u] * scaleU + offsetU
            ..[o + 19] = values[u + 1] * scaleV + offsetV;
        }
      }
      if (skinned) {
        for (var k = 0; k < 4; k++) {
          vertices
            ..[o + skinAt + k] = data[s + jointsAt! + k]
            ..[o + skinAt + 4 + k] = data[s + weightsAt! + k];
        }
      }
    }
    return Surface.fromBuffers(
      vertices: vertices,
      indices: source.indices,
      layout: target,
      material: material,
      jointMap: source.jointMap,
      morphTargets: source.morphTargets,
      aabb: Aabb3.copy(source.aabb),
      topology: source.topology,
      customAttributes: source.customAttributes,
    );
  }

  /// The defaults of the inputs, in the order of [_channels].
  static const List<double> _defaults = [0, 0, 0, 0, 1, 0, 0, 0];

  /// Converts every surface of [model]'s meshes in place (see
  /// [convertSurface]), each drawn with the [StylizedMaterial] that
  /// [materialFor] makes of its material, once per material. By default
  /// [materialFrom] makes them, and surfaces whose materials draw the same
  /// (the primitives that share a glTF material, which the readers give a
  /// material each) share one, so that they batch. Surfaces already drawn
  /// with a [StylizedMaterial] keep it, and surfaces already in its layout
  /// (with `vertexMasks`) are kept as they are.
  ///
  /// Convert a model before making components of it. What was mapped and
  /// what was dropped (custom attributes no channel reads, mapped attributes
  /// some surfaces lack, the parts of the materials a [StylizedMaterial]
  /// does not draw) is reported through [GltfWarnings] and returned.
  StylizedConversion convertModel(
    Model model, {
    StylizedMaterial Function(Material source)? materialFor,
  }) {
    final materials = Map<Material, StylizedMaterial>.identity();
    // The materials made by materialFrom, by what they draw: the glTF readers
    // give each primitive a material of its own, and primitives that share a
    // glTF material share one here.
    final shared = <Object, StylizedMaterial>{};
    final converted = Map<Surface, Surface>.identity();
    final meshes = Set<Mesh>.identity();
    final missing = <String>{};
    final present = <String>{};
    final droppedMaterial = <String>{};
    for (final node in model.nodes.values) {
      final mesh = node.mesh;
      if (mesh == null || !meshes.add(mesh)) {
        continue;
      }
      mesh.updateSurfaces((surfaces) {
        for (var i = 0; i < surfaces.length; i++) {
          final source = surfaces[i];
          if (source.layout.offsetOf(StylizedMaterial.masksAttribute) != null) {
            continue;
          }
          surfaces[i] = converted[source] ??= () {
            present.addAll(source.customAttributes.keys);
            final original = source.material;
            final material = materials[original] ??= () {
              droppedMaterial.addAll(_unsupportedParts(original));
              if (materialFor != null) {
                return materialFor(original);
              }
              final made = materialFrom(original);
              if (identical(made, original)) {
                return made;
              }
              return shared[_keyOf(made)] ??= made;
            }();
            final spatial = original is SpatialMaterial ? original : null;
            return convertSurface(
              source,
              material: material,
              uvScale: spatial?.uvScale,
              uvOffset: spatial?.uvOffset,
              missing: missing,
            );
          }();
        }
      });
    }

    final used = <String>{
      for (final (_, channel) in _channels) ?channel?.attribute,
      ?texCoord,
    };
    final mapped = {
      for (final (input, channel) in _channels)
        if (channel != null) input: channel.toString(),
      'texCoord': ?texCoord,
    };
    final dropped = present.difference(used);
    final conversion = StylizedConversion(
      surfaces: converted.length,
      mapped: mapped,
      dropped: dropped,
      missing: missing,
      droppedMaterialParts: droppedMaterial,
      materials: materials,
    );
    conversion.messages.forEach(GltfWarnings.report);
    return conversion;
  }

  /// What a material made by [materialFrom] draws.
  static Object _keyOf(StylizedMaterial material) => (
    material.albedoColor,
    material.baseColorTexture,
    material.alphaCutoff,
    material.renderState,
  );

  /// A [StylizedMaterial] that draws what it can of [source], as
  /// [convertModel] makes them: the base color and texture of a
  /// [SpatialMaterial] or an [UnlitMaterial] (glTF's base color factor and
  /// texture), its alpha cutoff (glTF `MASK`) and translucency (`BLEND`),
  /// and its cull mode (`doubleSided`). A [StylizedMaterial] is returned as
  /// it is; other materials give a default one with the same cull mode.
  static StylizedMaterial materialFrom(Material source) {
    if (source is StylizedMaterial) {
      return source;
    }
    final (color, texture, cutoff) = switch (source) {
      final SpatialMaterial m => (
        m.albedoColor,
        m.albedoTexture,
        m.alphaCutoff,
      ),
      final UnlitMaterial m => (m.albedoColor, m.albedoTexture, 0.0),
      _ => (const Color(0xFFFFFFFF), null, 0.0),
    };
    final baseColor = identical(texture, Texture.standard) ? null : texture;
    final material = StylizedMaterial(
      albedoColor: color,
      baseColorTexture: baseColor,
      alphaCutoff: baseColor == null ? 0 : cutoff,
      translucent: source.renderState.translucent,
    );
    material.renderState = material.renderState.copyWith(
      cullMode: source.renderState.cullMode,
    );
    return material;
  }

  /// The parts of [source] a [StylizedMaterial] made by [materialFrom] does
  /// not draw.
  static List<String> _unsupportedParts(Material source) => switch (source) {
    final SpatialMaterial m => [
      if (m.normalTexture != null) 'normal textures',
      if (m.metallicRoughnessTexture != null) 'metallic-roughness textures',
      if (m.occlusionTexture != null) 'occlusion textures',
      if (m.emissiveTexture != null) 'emissive textures',
      if (m.emissiveColor.toARGB32() & 0xFFFFFF != 0) 'emissive colors',
      if (m.alphaCutoff > 0 && identical(m.albedoTexture, Texture.standard))
        'alpha cutoffs without a texture',
    ],
    final UnlitMaterial _ => ['unlit shading (StylizedMaterial is lit)'],
    StylizedMaterial() => const [],
    _ => ['${source.runtimeType}'],
  };
}

/// {@template stylized_conversion}
/// What [StylizedVertexMapping.convertModel] did.
/// {@endtemplate}
class StylizedConversion({
  /// The number of surfaces converted.
  required final int surfaces,

  /// The inputs that were mapped, and from which channel (`_MASKS.y`, `1`).
  required final Map<String, String> mapped,

  /// The custom attributes of the surfaces that no channel reads: they are
  /// not drawn.
  required final Set<String> dropped,

  /// The mapped inputs that some surfaces could not read, as
  /// `input (attribute)`: they took their default there.
  required final Set<String> missing,

  /// The parts of the source materials the stylized ones do not draw.
  required final Set<String> droppedMaterialParts,

  /// The [StylizedMaterial] made for each source material.
  required final Map<Material, StylizedMaterial> materials,
}) {
  /// The messages [StylizedVertexMapping.convertModel] reports through
  /// [GltfWarnings], one per kind.
  List<String> get messages {
    String list(Iterable<String> names) => (names.toList()..sort()).join(', ');
    final pairs = [
      for (final MapEntry(:key, :value) in mapped.entries) '$key <- $value',
    ];
    final messages = <String>[];
    if (mapped.isNotEmpty) {
      messages.add(
        'StylizedMaterial conversion of $surfaces surfaces mapped '
        '${pairs.join(', ')}',
      );
    }
    if (dropped.isNotEmpty) {
      messages.add(
        'StylizedMaterial conversion dropped the custom attributes '
        '${list(dropped)}: no channel reads them',
      );
    }
    if (missing.isNotEmpty) {
      messages.add(
        'StylizedMaterial conversion: some surfaces lack ${list(missing)}, '
        'which take their default there',
      );
    }
    if (droppedMaterialParts.isNotEmpty) {
      messages.add(
        'StylizedMaterial conversion dropped the '
        '${list(droppedMaterialParts)} of the source materials',
      );
    }
    return messages;
  }
}
