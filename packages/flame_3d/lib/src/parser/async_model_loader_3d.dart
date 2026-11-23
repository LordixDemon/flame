import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/flame.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/parser/asset_scope_3d.dart';
import 'package:flame_3d/src/parser/gltf/gltf_warnings.dart';
import 'package:flame_3d/src/parser/meshopt_decoder_3d.dart';
import 'package:flame_3d/src/resources/texture/mipmaps.dart';

part 'async_model_loader_prepared_3d.dart';
part 'async_model_loader_workers_3d.dart';

// cSpell:ignore usemtl newmtl mtllib TEXCOORD CUBICSPLINE

/// Pure-CPU background isolate asset streamer (`Isolate.run` +
/// [TransferableTypedData]) for `.glb`, `.obj`, mipmap chains, and
/// [SurfaceBvh] acceleration structures.
abstract final class AsyncModelLoader3D() {
  /// Loads a `.glb` asset via `Flame.assets` and prepares all geometry,
  /// skinning, morph targets, and animations on a background isolate.
  ///
  /// With [buildBvhs] (the default) the ray-casting BVH of every surface is
  /// built on a second background isolate before the model is returned (see
  /// [buildSurfaceBvhsInIsolate]); pass `false` when the model is not ray
  /// cast. Images are decoded and textures created on the main isolate.
  static Future<Model> loadGlbAssetAsync(
    String filePath, {
    bool buildBvhs = true,
    AssetScope3D? scope,
  }) async {
    final bytes = await Flame.assets.readBinaryFile(filePath);
    final slash = filePath.lastIndexOf('/');
    final prefix = slash >= 0 ? filePath.substring(0, slash + 1) : '';
    return await parseGlbBytesAsync(
      bytes,
      prefix: prefix,
      buildBvhs: buildBvhs,
      scope: scope,
    );
  }

  /// Parses raw `.glb` [bytes] inside a background isolate using zero-copy
  /// [TransferableTypedData] buffers, decodes any embedded textures, and
  /// returns a ready-to-render [Model].
  static Future<Model> parseGlbBytesAsync(
    Uint8List bytes, {
    String prefix = '',
    bool buildBvhs = true,
    AssetScope3D? scope,
  }) async {
    final inputTransfer = TransferableTypedData.fromList([bytes]);
    final prepared = await Isolate.run(
      () => _prepareGlbInIsolate(inputTransfer, prefix),
    );
    final model = await _materializePreparedGlb(prepared);
    if (buildBvhs) {
      await buildSurfaceBvhsInIsolate(model);
    }
    scope?.retain(model);
    return model;
  }

  /// Parses Wavefront `.obj` UTF-8 [bytes] inside a background isolate into
  /// packed `VertexLayout.standard` buffers and returns a [Model].
  static Future<Model> parseObjBytesAsync(
    Uint8List bytes, {
    Map<String, String> mtlSources = const {},
    bool buildBvhs = true,
    AssetScope3D? scope,
  }) async {
    final inputTransfer = TransferableTypedData.fromList([bytes]);
    final prepared = await Isolate.run(() {
      final text = utf8.decode(inputTransfer.materialize().asUint8List());
      return _prepareObjInIsolate(text, mtlSources);
    });
    final model = _materializePreparedObj(prepared);
    if (buildBvhs) {
      await buildSurfaceBvhsInIsolate(model);
    }
    scope?.retain(model);
    return model;
  }

  /// Parses Wavefront `.obj` source text inside a background isolate into
  /// packed `VertexLayout.standard` buffers and returns a [Model].
  static Future<Model> parseObjStringInIsolate(
    String objSource, {
    Map<String, String> mtlSources = const {},
    bool buildBvhs = true,
    AssetScope3D? scope,
  }) async {
    final prepared = await Isolate.run(
      () => _prepareObjInIsolate(objSource, mtlSources),
    );
    final model = _materializePreparedObj(prepared);
    if (buildBvhs) {
      await buildSurfaceBvhsInIsolate(model);
    }
    scope?.retain(model);
    return model;
  }

  /// Builds flat median-split triangle BVHs for every [Surface] in [model] on a
  /// background isolate using [TransferableTypedData], hands each to its
  /// surface ([Surface.adoptBvh], so `surface.bvh` is not rebuilt on the main
  /// isolate), and returns the prepared BVH payloads.
  ///
  /// The vertex and index data are copied to the isolate. A surface whose
  /// vertices change afterwards (morph targets) drops its BVH and builds the
  /// next one on the main isolate when ray cast.
  static Future<List<PreparedSurfaceBvh3D>> buildSurfaceBvhsInIsolate(
    Model model, {
    int maxLeafTriangles = 4,
  }) async {
    if (maxLeafTriangles < 1) {
      throw ArgumentError.value(
        maxLeafTriangles,
        'maxLeafTriangles',
        'Must be >= 1',
      );
    }
    final surfaces = <Surface>[];
    final seen = <Surface>{};
    for (final node in model.nodes.values) {
      final mesh = node.mesh;
      if (mesh == null) {
        continue;
      }
      for (final s in mesh.surfaces) {
        if (seen.add(s)) {
          surfaces.add(s);
        }
      }
    }
    if (surfaces.isEmpty) {
      return const [];
    }

    final inputs = <_BvhSurfaceInput>[];
    for (var i = 0; i < surfaces.length; i++) {
      final s = surfaces[i];
      final posOffset = s.layout.offsetOf(VertexLayout.positionAttribute) ?? 0;
      final idxList = s.indices;
      final isWide = idxList is Uint32List;
      final idxBytes = isWide
          ? idxList.buffer.asUint8List(
              idxList.offsetInBytes,
              idxList.lengthInBytes,
            )
          : (idxList as Uint16List).buffer.asUint8List(
              idxList.offsetInBytes,
              idxList.lengthInBytes,
            );
      final vertBytes = s.vertexData.buffer.asUint8List(
        s.vertexData.offsetInBytes,
        s.vertexData.lengthInBytes,
      );
      inputs.add(
        _BvhSurfaceInput(
          surfaceIndex: i,
          stride: s.layout.strideInFloats,
          posOffset: posOffset,
          wideIndices: isWide,
          vertices: TransferableTypedData.fromList([vertBytes]),
          indices: TransferableTypedData.fromList([idxBytes]),
        ),
      );
    }

    final rawOutputs = await Isolate.run(
      () => _buildBvhsWorker(inputs, maxLeafTriangles),
    );

    final results = <PreparedSurfaceBvh3D>[];
    for (var i = 0; i < rawOutputs.length; i++) {
      final r = rawOutputs[i];
      final prepared = PreparedSurfaceBvh3D(
        surfaceIndex: r.surfaceIndex,
        nodeCount: r.nodeCount,
        triangleCount: r.triangleCount,
        bounds: r.bounds.materialize().asFloat32List(),
        leftOrFirst: r.leftOrFirst.materialize().asInt32List(),
        rightChild: r.rightChild.materialize().asInt32List(),
        counts: r.counts.materialize().asInt32List(),
        triangles: r.triangles.materialize().asInt32List(),
      );
      // The surface uses the hierarchy built on the isolate: no rebuild on
      // the main isolate.
      final surface = surfaces[r.surfaceIndex];
      surface.adoptBvh(
        SurfaceBvh.fromPrepared(
          surface: surface,
          nodeCount: prepared.nodeCount,
          bounds: prepared.bounds,
          leftOrFirst: prepared.leftOrFirst,
          rightChild: prepared.rightChild,
          counts: prepared.counts,
          triangles: prepared.triangles,
        ),
      );
      results.add(prepared);
    }
    return results;
  }

  /// Generates a complete CPU box-filtered RGBA8888 mipmap chain (from level
  /// `0` `[width x height]` down to `1x1`) in a background isolate via
  /// [TransferableTypedData].
  static Future<List<Uint8List>> generateMipmapsInIsolate(
    Uint8List rgbaPixels, {
    required int width,
    required int height,
  }) async {
    if (width < 1 || height < 1) {
      throw ArgumentError('width and height must be >= 1');
    }
    if (rgbaPixels.length < width * height * 4) {
      throw ArgumentError('rgbaPixels smaller than width * height * 4');
    }
    final input = TransferableTypedData.fromList([rgbaPixels]);
    final transfers = await Isolate.run(() {
      final level0 = input.materialize().asUint8List();
      final out = <TransferableTypedData>[
        TransferableTypedData.fromList([level0]),
      ];
      var curData = ByteData.sublistView(level0, 0, width * height * 4);
      var curW = width;
      var curH = height;
      while (curW > 1 || curH > 1) {
        final next = Mipmaps.downsample(
          curData,
          curW,
          curH,
          ui.PixelFormat.rgba8888,
        );
        final (nw, nh) = Mipmaps.levelSize(curW, curH, 1);
        final bytes = next.buffer.asUint8List(
          next.offsetInBytes,
          next.lengthInBytes,
        );
        out.add(TransferableTypedData.fromList([bytes]));
        curData = next;
        curW = nw;
        curH = nh;
      }
      return out;
    });
    return [for (final t in transfers) t.materialize().asUint8List()];
  }

  // ---------------------------------------------------------------------------
  // Pure-Dart BVH worker
  // ---------------------------------------------------------------------------
}
