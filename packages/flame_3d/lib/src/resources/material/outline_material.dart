import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/resources/material/material_apply_cache.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// {@template outline_material}
/// An instanced inverted-hull silhouette contour material.
///
/// Extrudes vertices outward along their normals and culls front faces
/// ([CullMode.frontFace]), leaving a clean silhouette rim around any closed 3D
/// mesh (both static and skinned).
///
/// When [screenSpace] is `false` (the default), [thickness] is measured in
/// world units. When [screenSpace] is `true`, [thickness] is expressed as a
/// fraction of viewport height in clip space (`0.01` = 0.5 % of viewport height
/// on each side), keeping the stroke width invariant to camera distance and 2D
/// zoom.
///
/// Instances drawn with one [OutlineMaterial] still batch into a single draw
/// call while varying through:
/// - `MeshComponent.color` (`instanceColor`), multiplied into [color];
/// - `MeshComponent.instanceData.x`, added to `1.0` to scale [thickness]
///   (`-1` hides the outline, `1` doubles it);
/// - `MeshComponent.instanceData.y`, added to [depthBias].
/// {@endtemplate}
class OutlineMaterial({
  var Color _color = const Color(0xFF1A1614),
  var double _thickness = 0.03,
  var bool _screenSpace = false,
  var double _depthBias = 0.0005,
}) extends Material {
  /// {@macro outline_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: const [RenderContext3D.cameraMatricesBlock, 'Outline'],
        ),
        fragmentShader: FragmentShader.fromAsset(_bundle),
      ) {
    if (kIsWeb) {
      throw UnsupportedError('OutlineMaterial is not supported on the web yet');
    }
    setInitialState(
      renderState: const RenderState(cullMode: CullMode.frontFace),
      castsShadows: false,
    );
  }

  /// Base contour color and opacity.
  Color get color => _color;
  set color(Color value) => _color = noteChange(_color, value);

  /// Contour width (in world units when [screenSpace] is `false`, or in
  /// clip-height fraction when [screenSpace] is `true`).
  double get thickness => _thickness;
  set thickness(double value) => _thickness = noteChange(_thickness, value);

  /// Whether [thickness] is evaluated in screen/clip space rather than world
  /// units.
  bool get screenSpace => _screenSpace;
  set screenSpace(bool value) => _screenSpace = noteChange(_screenSpace, value);

  /// Clip-space depth bias (`>= 0`) nudging the extruded back faces slightly
  /// away from the camera so interior creases do not poke through front faces.
  double get depthBias => _depthBias;
  set depthBias(double value) => _depthBias = noteChange(_depthBias, value);

  static const String _bundle =
      'packages/flame_3d/assets/shaders/outline_material.shaderbundle';
  static const String _skinnedBundle =
      'packages/flame_3d/assets/shaders/outline_material_skinned.shaderbundle';

  final Shader _skinnedVertexShader = VertexShader.fromAsset(
    _skinnedBundle,
    slots: const [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
      'Outline',
    ],
  );

  bool _skinnedInUse = false;
  final VertexShaderLayoutCache _vertexLayoutCache = VertexShaderLayoutCache();

  int _appliedVersion = -1;
  Shader? _appliedVert;
  int _appliedVertGen = -1;
  double _appliedAspect = double.nan;

  @override
  Shader vertexShaderFor(VertexLayout layout) {
    final cached = _vertexLayoutCache.lookup(layout);
    if (cached != null) {
      return cached;
    }
    final skinned =
        layout.offsetOf('vertexJoints') != null &&
        layout.offsetOf('vertexWeights') != null;
    if (skinned) {
      _skinnedInUse = true;
      return _vertexLayoutCache.store(layout, _skinnedVertexShader);
    }
    return _vertexLayoutCache.store(layout, vertexShader);
  }

  @override
  bool get hasPassStableFragmentShader => runtimeType == OutlineMaterial;

  @override
  bool get cachesApply => runtimeType == OutlineMaterial;

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
    return _appliedVersion == version &&
        identical(_appliedVert, vertexShader) &&
        _appliedVertGen == vertexShader.generation &&
        _appliedAspect == _aspectOf(context);
  }

  @override
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    _appliedVersion = version;
    _appliedVert = vertexShader;
    _appliedVertGen = vertexShader.generation;
    _appliedAspect = _aspectOf(context);
  }

  static double _aspectOf(RenderContext context) {
    if (context is RenderContext3D) {
      final p = context.projection.storage;
      if (p[0].abs() > 1e-6 && p[5].abs() > 1e-6) {
        return (p[0] / p[5]).abs();
      }
    }
    return 1.0;
  }

  void _writeShader(Shader target, double aspect) {
    target.resource;
    final idx = target.blockIndexOf('Outline');
    if (idx < 0) {
      return;
    }
    final block = target.blockAt(idx);
    final off =
        (block.cachedWriterOffsets as _OutlineOffsets?) ??
        (block.cachedWriterOffsets = _OutlineOffsets(block));
    if (off._color >= 0) {
      block.writeColorAt(off._color, color);
    }
    if (off._params >= 0) {
      block.writeVec4ValuesAt(
        off._params,
        thickness,
        depthBias,
        screenSpace ? 1.0 : 0.0,
        aspect,
      );
    }
  }

  @override
  void apply(RenderContext context) {
    final aspect = _aspectOf(context);
    final activeVert = context is RenderContext3D
        ? context.activeApplyVertexShader
        : null;
    if (activeVert != null) {
      _writeShader(activeVert, aspect);
    } else {
      _writeShader(vertexShader, aspect);
      if (_skinnedInUse) {
        _writeShader(_skinnedVertexShader, aspect);
      }
    }
  }
}

class _OutlineOffsets(final UniformBlock _b) {
  late final int _color = _b.resolveOffset('color');
  late final int _params = _b.resolveOffset('params');
}
