import 'dart:typed_data';

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// Shared fullscreen clip-space quad used by post-processing, WBOIT composite,
/// and scratch-copy passes.
@internal
final Surface fullscreenQuadSurface = Surface.fromBuffers(
  vertices: Float32List.fromList(const [
    -1.0, -1.0, 0.0, //
    1.0, -1.0, 0.0, //
    1.0, 1.0, 0.0, //
    -1.0, 1.0, 0.0, //
  ]),
  indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
  layout: VertexLayout(const [
    VertexAttribute(VertexLayout.positionAttribute, 3),
  ]),
);

/// Depth-disabled render state paired with [fullscreenQuadSurface].
@internal
const RenderState fullscreenQuadState = RenderState(
  depthTest: false,
  depthWrite: false,
);
