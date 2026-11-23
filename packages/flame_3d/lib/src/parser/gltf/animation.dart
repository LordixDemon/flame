import 'package:flame_3d/core.dart' show AnimationInterpolation;
import 'package:flame_3d/src/model/model_animation.dart';
import 'package:flame_3d/src/parser/gltf/accessor.dart';
import 'package:flame_3d/src/parser/gltf/gltf_enums.dart';
import 'package:flame_3d/src/parser/gltf/gltf_node.dart';
import 'package:flame_3d/src/parser/gltf/gltf_root.dart';
import 'package:flame_3d/src/parser/gltf/gltf_scene_graph.dart';
import 'package:flame_3d/src/parser/gltf/gltf_warnings.dart';

class AnimationChannel({
  required super.root,

  /// The ID of a sampler in this animation used to compute the value for the
  /// target, e.g., a node's translation, rotation, or scale (TRS).
  required final int sampler,

  /// The descriptor of the animated property.
  required final AnimationTarget target,
}) extends GltfNode {
  AnimationChannel.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        sampler: Parser.integer(map, 'sampler')!,
        target: Parser.object(root, map, 'target', AnimationTarget.parse)!,
      );
}

/// An animation sampler combines timestamps with a sequence of output values
/// and defines an interpolation algorithm.
class AnimationSampler({
  required super.root,

  /// The index of an accessor containing keyframe timestamps.
  /// The accessor **MUST** be of scalar type with floating-point components.
  /// The values represent time in seconds with `time[0] >= 0.0`, and strictly
  /// increasing values, i.e., `time[n + 1] > time[n]`.
  required final GltfRef<FloatAccessor> input,

  /// Interpolation algorithm.
  required final AnimationInterpolation interpolation,

  /// The index of an accessor, containing keyframe output values.
  required final GltfRef<RawAccessor> output,
}) extends GltfNode {
  AnimationSampler.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        input: Parser.ref(root, map, 'input')!,
        interpolation:
            Parser.stringEnum(
              map,
              'interpolation',
              AnimationInterpolation.valueOf,
            ) ??
            AnimationInterpolation.linear,
        output: Parser.ref(root, map, 'output')!,
      );
}

/// The descriptor of the animated property.
class AnimationTarget({
  required super.root,

  /// The reference to the node to animate. When undefined, the animated object
  /// **MAY** be defined by an extension.
  required final GltfRef<Node>? node,

  /// The name of the node's TRS property to animate, or the `weights` of the
  /// Morph Targets it instantiates.
  /// For the `translation` property, the values that are provided by the
  /// sampler are the translation along the X, Y, and Z axes.
  /// For the `rotation` property, the values are a quaternion in the order
  /// (x, y, z, w), where w is the scalar.
  /// For the `scale` property, the values are the scaling factors along the
  /// X, Y, and Z axes.
  ///
  /// `null` for paths this reader does not animate, such as the `pointer`
  /// of `KHR_animation_pointer` (see [rawPath]).
  required final AnimationPath? path,

  /// The `path` as written in the file.
  final String? rawPath,
}) extends GltfNode {
  AnimationTarget.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        node: Parser.ref(root, map, 'node'),
        path: AnimationPath.tryParse(Parser.string(map, 'path')),
        rawPath: Parser.string(map, 'path'),
      );
}

/// A keyframe animation.
class Animation({
  required super.root,
  required final String? name,
  required final List<AnimationChannel> channels,
  required final List<AnimationSampler> samplers,
}) extends GltfNode {
  Animation.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        name: Parser.string(map, 'name'),
        channels: Parser.objectList(
          root,
          map,
          'channels',
          AnimationChannel.parse,
        )!,
        samplers: Parser.objectList(
          root,
          map,
          'samplers',
          AnimationSampler.parse,
        )!,
      );

  ModelAnimation toFlameAnimation() {
    final controllers = <int, List<AnimationController>>{};
    final morphChannels = <int, MorphWeightsChannel>{};

    for (final channel in channels) {
      final path = channel.target.path;
      final node = channel.target.node;
      if (path == null || node == null) {
        GltfWarnings.report(
          'animation channels targeting "${channel.target.rawPath}" are '
          'skipped: only node translation, rotation, scale and weights are '
          'animated',
        );
        continue;
      }
      final sampler = samplers[channel.sampler];
      final nodeIndex = node.index;

      final times = sampler.input.get().typedData();
      final values = sampler.output.get();

      if (path == AnimationPath.weights) {
        final rawWeights = values.asFloat().typedData();
        final divisor =
            sampler.interpolation == AnimationInterpolation.cubicSpline
            ? times.length * 3
            : times.length;
        final targetCount = divisor > 0 ? rawWeights.length ~/ divisor : 0;
        if (targetCount > 0) {
          morphChannels[nodeIndex] = MorphWeightsChannel(
            interpolation: sampler.interpolation,
            times: times,
            weights: rawWeights,
            targetCount: targetCount,
          );
        }
        continue;
      }

      final spline = switch (path) {
        AnimationPath.translation => TranslationAnimationSpline.from(
          interpolation: sampler.interpolation,
          times: times,
          values: values.asVector3().typedData(),
        ),
        AnimationPath.scale => ScaleAnimationSpline.from(
          interpolation: sampler.interpolation,
          times: times,
          values: values.asVector3().typedData(),
        ),
        AnimationPath.rotation => RotationAnimationSpline.from(
          interpolation: sampler.interpolation,
          times: times,
          values: values.asQuaternion().typedData(),
        ),
        AnimationPath.weights => throw StateError('Unreachable'),
      } as AnimationSpline;

      (controllers[nodeIndex] ??= []).add(
        AnimationController(
          animation: spline,
        ),
      );
    }

    final allNodeIndices = <int>{...controllers.keys, ...morphChannels.keys};
    final nodes = <int, NodeAnimation>{
      for (final idx in allNodeIndices)
        idx: NodeAnimation(
          channels: controllers[idx] ?? const [],
          morphWeights: morphChannels[idx],
        ),
    };
    return ModelAnimation(
      name: name,
      nodes: nodes,
    );
  }
}
