part of 'graphics_device.dart';

/// {@template device_pipeline}
/// A render pipeline built by a [GraphicsDevice] for one vertex shader,
/// fragment shader and surface [VertexLayout], with what the device learned
/// about how it reads its inputs.
/// {@endtemplate}
class DevicePipeline._(
  /// The backend pipeline.
  final GpuPipeline pipeline, {

  /// The backend vertex shader linked into this pipeline.
  required final GpuShader vertexShader,

  /// The backend fragment shader linked into this pipeline.
  required final GpuShader fragmentShader,

  /// A number identifying this pipeline within its device, usable to sort
  /// draws by pipeline.
  required final int id,

  /// Whether the vertex shader reads per-instance data, so an instance buffer
  /// must be bound for every draw.
  required final bool usesInstanceData,

  /// Whether the vertex shader reads its model matrix from the instance data,
  /// so draws of the same surface and material can be batched into one
  /// instanced draw.
  required final bool instanced,
}) {
  factory DevicePipeline._create(
    GpuBackend backend,
    GpuShader vertexShader,
    GpuShader fragmentShader,
    VertexLayout layout,
    int id,
  ) {
    final vertexAttributes = <GpuVertexAttribute>[];
    final instanceAttributes = <GpuVertexAttribute>[];
    final inputs = vertexShader.inputs;

    void addInstanceAttribute(int index, String name, int location) {
      instanceAttributes.add(
        GpuVertexAttribute(
          name: name,
          location: location,
          components: VertexLayout.instanceAttributes[index].components,
          offsetInBytes: index * 16,
        ),
      );
    }

    if (inputs == null) {
      for (final (index, attribute) in layout.attributes.indexed) {
        vertexAttributes.add(
          GpuVertexAttribute(
            name: attribute.name,
            location: index,
            components: attribute.components,
            offsetInBytes: layout.offsetOf(attribute.name)! * 4,
          ),
        );
      }
      for (final (index, attribute)
          in VertexLayout.instanceAttributes.indexed) {
        addInstanceAttribute(
          index,
          attribute.name,
          layout.attributes.length + index,
        );
      }
    } else {
      for (final input in inputs) {
        final attribute = layout.attribute(input.name);
        if (attribute != null) {
          vertexAttributes.add(
            GpuVertexAttribute(
              name: input.name,
              location: input.location,
              components: attribute.components,
              offsetInBytes: layout.offsetOf(input.name)! * 4,
            ),
          );
          continue;
        }
        final instanceIndex = VertexLayout.instanceAttributes.indexWhere(
          (a) => a.name == input.name,
        );
        if (instanceIndex < 0) {
          final instanceInputs = VertexLayout.instanceAttributes
              .map((a) => a.name)
              .join(', ');
          throw StateError(
            'The vertex shader input "${input.name}" is not provided by the '
            'surface vertex layout $layout, nor is it an instance input '
            '($instanceInputs)',
          );
        }
        addInstanceAttribute(instanceIndex, input.name, input.location);
      }
    }

    final modelColumns = instanceAttributes
        .where((a) => a.name.startsWith('instanceModel'))
        .length;
    if (modelColumns != 0 && modelColumns != 4) {
      throw StateError(
        'A vertex shader must declare all four instanceModel columns or none',
      );
    }

    final pipeline = backend.createPipeline(
      vertexShader: vertexShader,
      fragmentShader: fragmentShader,
      vertexLayout: GpuVertexLayout([
        GpuVertexBufferLayout(
          strideInBytes: layout.strideInBytes,
          attributes: vertexAttributes,
        ),
        if (instanceAttributes.isNotEmpty)
          GpuVertexBufferLayout(
            strideInBytes: VertexLayout.instanceStrideInFloats * 4,
            attributes: instanceAttributes,
            perInstance: true,
          ),
      ]),
    );
    return DevicePipeline._(
      pipeline,
      vertexShader: vertexShader,
      fragmentShader: fragmentShader,
      id: id,
      usesInstanceData: instanceAttributes.isNotEmpty,
      instanced: modelColumns == 4,
    );
  }
}
