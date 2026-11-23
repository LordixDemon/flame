import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// The pipeline a [Material] drew with last, so that the [RenderContext3D]
/// does not look it up for every draw.
@internal
class MaterialPipelineCache({
  required final GraphicsDevice device,
  required final VertexLayout layout,
  required final Shader vertexShader,
  required final Shader fragmentShader,
  required final int vertexGeneration,
  required final int fragmentGeneration,
  required final DevicePipeline pipeline,
});
