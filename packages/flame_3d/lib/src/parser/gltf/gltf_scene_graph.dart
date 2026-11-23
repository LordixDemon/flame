import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart' as flame_3d;
import 'package:flame_3d/src/parser/gltf/accessor.dart';
import 'package:flame_3d/src/parser/gltf/gltf_enums.dart';
import 'package:flame_3d/src/parser/gltf/gltf_extensions.dart';
import 'package:flame_3d/src/parser/gltf/gltf_node.dart';
import 'package:flame_3d/src/parser/gltf/gltf_root.dart';
import 'package:flame_3d/src/parser/gltf/gltf_warnings.dart';
import 'package:flame_3d/src/parser/gltf/primitive.dart';

/// A camera's projection.
///
/// A node **MAY** reference a camera to apply a transform to place the camera
/// in the scene.
class Camera({
  required super.root,

  /// Specifies if the camera uses a perspective or orthographic projection.
  /// Based on this, either the camera's `perspective` or `orthographic`
  /// property **MUST** be defined.
  required final CameraType type,

  /// An orthographic camera containing properties to create an orthographic
  /// projection matrix.
  /// This property **MUST NOT** be defined when `perspective` is defined.
  required final CameraOrthographic? orthographic,

  /// A perspective camera containing properties to create a perspective
  /// projection matrix.
  /// This property **MUST NOT** be defined when `orthographic` is defined.
  required final CameraPerspective? perspective,
}) extends GltfNode {
  Camera.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        type: CameraType.parse(map, 'type')!,
        orthographic: Parser.object(
          root,
          map,
          'orthographic',
          CameraOrthographic.parse,
        ),
        perspective: Parser.object(
          root,
          map,
          'perspective',
          CameraPerspective.parse,
        ),
      );
}

/// An orthographic camera containing properties to create an orthographic
/// projection matrix.
class CameraOrthographic({
  required super.root,

  /// The floating-point horizontal magnification of the view.
  /// This value **MUST NOT** be equal to zero.
  /// This value **SHOULD NOT** be negative.
  required final double xMag,

  /// The floating-point vertical magnification of the view.
  /// This value **MUST NOT** be equal to zero.
  /// This value **SHOULD NOT** be negative.
  required final double yMag,

  /// The floating-point distance to the far clipping plane.
  /// This value **MUST NOT** be equal to zero.
  /// `zFar` **MUST** be greater than `zNear`.
  required final double xFar,

  /// The floating-point distance to the near clipping plane.
  required final double zNear,
}) extends GltfNode {
  CameraOrthographic.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        xMag: Parser.float(map, 'xmag')!, // cSpell:ignore xmag
        yMag: Parser.float(map, 'ymag')!, // cSpell:ignore ymag
        xFar: Parser.float(map, 'zfar')!, // cSpell:ignore zfar
        zNear: Parser.float(map, 'znear')!, // cSpell:ignore znear
      );
}

/// A perspective camera containing properties to create a perspective
/// projection matrix.
class CameraPerspective({
  required super.root,

  /// The floating-point aspect ratio of the field of view.
  /// When undefined, the aspect ratio of the rendering viewport **MUST** be
  /// used.
  required final double? aspectRatio,

  /// The floating-point vertical field of view in radians.
  /// This value **SHOULD** be less than π.
  required final double yFov,

  /// The floating-point distance to the far clipping plane.
  /// When defined, `zFar` **MUST** be greater than `zNear`.
  /// If `zFar` is undefined, client implementations **SHOULD** use
  /// infinite projection matrix.
  required final double? zFar,

  /// The floating-point distance to the near clipping plane.
  required final double zNear,
}) extends GltfNode {
  CameraPerspective.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        aspectRatio: Parser.float(map, 'aspectRatio'),
        yFov: Parser.float(map, 'yfov')!, // cSpell:ignore yfov
        zFar: Parser.float(map, 'zfar'), // cSpell:ignore zfar
        zNear: Parser.float(map, 'znear')!, // cSpell:ignore znear
      );
}

/// A plain JSON object specifying attributes displacements in a morph target,
/// where:
/// * each key corresponds to one of the three supported attribute semantic
///   (`POSITION`, `NORMAL`, or `TANGENT`); and
/// * each value is the index of the accessor containing the attribute
///   displacements' data.
class MorphTarget({
  required super.root,
  required var Map<MorphTargetType, GltfRef<RawAccessor>> attributes,
}) extends GltfNode {
  MorphTarget.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        attributes: map.map(
          (key, value) => MapEntry(
            MorphTargetType.valueOf(key),
            GltfRef<RawAccessor>(root: root, index: value! as int),
          ),
        ),
      );
}

enum MorphTargetType(final String value) {
  position('POSITION'),
  normal('NORMAL'),
  tangent('TANGENT');

  static MorphTargetType valueOf(String value) {
    return values.firstWhere((e) => e.value == value);
  }
}

/// A set of primitives to be rendered.
class Mesh({
  required super.root,
  required final List<Primitive> primitives,
  required final List<double>? weights,
}) extends GltfNode {
  Mesh.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        primitives:
            Parser.objectList(root, map, 'primitives', Primitive.parse) ?? [],
        weights: Parser.floatList(map, 'weights'),
      );

  /// Builds the surfaces of every drawable primitive (points and lines are
  /// skipped and reported, see [GltfWarnings]) and applies the morph
  /// [weights] of the node that instantiates the mesh, or the mesh's own
  /// [weights] when `null`.
  flame_3d.Mesh toFlameMesh([
    Matrix4? transform,
    List<double>? nodeWeights,
  ]) {
    final mesh = flame_3d.Mesh();
    final initialWeights = nodeWeights ?? weights;
    for (final primitive in primitives) {
      if (!primitive.isTriangles) {
        GltfWarnings.report(
          'primitives of mode ${primitive.mode.name} are skipped: only '
          'triangles, triangle strips and triangle fans can be drawn',
        );
        continue;
      }
      for (final surface in primitive.toFlameSurfaces(transform)) {
        if (initialWeights != null && initialWeights.isNotEmpty) {
          surface.applyMorphWeights(initialWeights);
        }
        mesh.addSurface(surface);
      }
    }
    return mesh;
  }
}

/// Joints and matrices defining a skin.
class Skin({
  required super.root,

  /// The reference to the accessor containing the floating-point 4x4
  /// inverse-bind matrices.
  /// Its `accessor.count` property **MUST** be greater than or equal to the
  /// number of elements of the `joints` array.
  /// When undefined, each matrix is a 4x4 identity matrix.
  required final GltfRef<Matrix4Accessor>? inverseBindMatrices,

  /// The reference to the node used as a skeleton root.
  /// The node **MUST** be the closest common root of the joints hierarchy or a
  /// direct or indirect parent node of the closest common root.
  required final GltfRef<Node>? skeleton,

  /// Indices of skeleton nodes, used as joints in this skin.
  required final List<GltfRef<Node>> joints,
}) extends GltfNode {
  Skin.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        inverseBindMatrices: Parser.ref(root, map, 'inverseBindMatrices'),
        skeleton: Parser.ref(root, map, 'skeleton'),
        joints: Parser.refList<Node>(root, map, 'joints') ?? [],
      );
}

/// A node in the node hierarchy.
///
/// When the node contains `skin`, all `mesh.primitives` **MUST** contain
/// `JOINTS_0` and `WEIGHTS_0` attributes.
///
/// A node **MAY** have either a `matrix` or any combination of
/// `translation`/`rotation`/`scale` (TRS) properties.
class Node({
  required super.root,

  /// The reference to the camera referenced by this node.
  required final GltfRef<Camera>? camera,

  /// The references to this node's children.
  required final List<GltfRef<Node>> children,

  /// The reference to skeleton nodes.
  required final List<GltfRef<Node>> skeletons,

  /// The reference to the skin referenced by this node.
  required final GltfRef<Skin>? skin,

  /// Name used when this node is a joint in a skin.
  required final String? jointName,

  /// A floating-point 4x4 transformation matrix stored in column-major order.
  required final Matrix4? matrix,

  /// The reference to the mesh in this node.
  required final GltfRef<Mesh>? mesh,

  /// The node's unit quaternion rotation in the order (x, y, z, w).
  required final Quaternion? rotation,

  /// The node's non-uniform scale along the x, y, and z axes.
  required final Vector3? scale,

  /// The node's translation along the x, y, and z axes.
  required final Vector3? translation,

  /// The weights of the instantiated morph target.
  required final List<double>? weights,
  required final String? name,
  final Map<String, Object?>? extensions,
  final Object? extras,
}) extends GltfNode {
  Node.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        camera: Parser.ref(root, map, 'camera'),
        children: Parser.refList(root, map, 'children') ?? [],
        skeletons: Parser.refList(root, map, 'skeletons') ?? [],
        skin: Parser.ref(root, map, 'skin'),
        jointName: Parser.string(map, 'jointName'),
        matrix: Parser.matrix4(root, map, 'matrix'),
        mesh: Parser.ref(root, map, 'mesh'),
        rotation: Parser.quaternion(root, map, 'rotation'),
        scale: Parser.vector3(root, map, 'scale'),
        translation: Parser.vector3(root, map, 'translation'),
        weights: Parser.floatList(map, 'weights'),
        name: Parser.string(map, 'name'),
        extensions: Parser.extensions(map),
        extras: Parser.extras(map),
      );

  /// Index into [GltfRoot.punctualLights] when `KHR_lights_punctual` is
  /// attached to this node, or `null`.
  int? get punctualLightIndex {
    final ext = extensions?['KHR_lights_punctual'];
    if (ext is Map<String, Object?>) {
      return Parser.integer(ext, 'light');
    }
    return null;
  }

  /// Resolved [KhrPunctualLight] attached to this node via
  /// `KHR_lights_punctual`, or `null`.
  KhrPunctualLight? get punctualLight {
    final idx = punctualLightIndex;
    if (idx == null || idx < 0 || idx >= root.punctualLights.length) {
      return null;
    }
    return root.punctualLights[idx];
  }

  /// Local instance transforms parsed from `EXT_mesh_gpu_instancing`
  /// (`TRANSLATION`, `ROTATION`, `SCALE` accessors), empty when the extension
  /// is absent.
  late final List<Matrix4> gpuInstanceTransforms = _parseGpuInstances();

  List<Matrix4> _parseGpuInstances() {
    final ext = extensions?['EXT_mesh_gpu_instancing'];
    if (ext is! Map<String, Object?>) {
      return const [];
    }
    final attrs = ext['attributes'];
    if (attrs is! Map<String, Object?>) {
      return const [];
    }
    final tIdx = Parser.integer(attrs, 'TRANSLATION');
    final rIdx = Parser.integer(attrs, 'ROTATION');
    final sIdx = Parser.integer(attrs, 'SCALE');
    if (tIdx == null && rIdx == null && sIdx == null) {
      return const [];
    }

    final translations = tIdx != null
        ? root.resolve<Vector3Accessor>(tIdx).typedData()
        : null;
    final rotations = rIdx != null
        ? root.resolve<QuaternionAccessor>(rIdx).typedData()
        : null;
    final scales = sIdx != null
        ? root.resolve<Vector3Accessor>(sIdx).typedData()
        : null;

    final count = math.max(
      translations?.length ?? 0,
      math.max(rotations?.length ?? 0, scales?.length ?? 0),
    );
    if (count <= 0) {
      return const [];
    }

    final zero = Vector3.zero();
    final identityQ = Quaternion.identity();
    final unitScale = Vector3.all(1.0);
    return List<Matrix4>.unmodifiable([
      for (var i = 0; i < count; i++)
        Matrix4.compose(
          translations != null && i < translations.length
              ? translations[i]
              : zero,
          rotations != null && i < rotations.length
              ? (rotations[i].clone()..normalize())
              : identityQ,
          scales != null && i < scales.length ? scales[i] : unitScale,
        ),
    ]);
  }

  Matrix4? get _trs {
    if (translation == null && rotation == null && scale == null) {
      return null;
    }
    return Matrix4.compose(
      translation ?? Vector3.zero(),
      rotation ?? Quaternion.identity(),
      scale ?? Vector3.all(1.0),
    );
  }

  Matrix4 get transform => matrix ?? _trs ?? Matrix4.identity();
}

/// The root nodes of a scene.
class Scene({
  required super.root,

  /// The references to each root node.
  required final List<GltfRef<Node>> nodes,
}) extends GltfNode {
  Scene.parse(
    GltfRoot root,
    Map<String, Object?> map,
  ) : this(
        root: root,
        nodes: Parser.refList<Node>(root, map, 'nodes')!,
      );

  Map<int, ModelNode> toFlameNodes() {
    final nodes = <int, ModelNode>{};
    for (final nodeRef in this.nodes) {
      _processNode(
        nodes: nodes,
        parent: null,
        nodeRef: nodeRef,
      );
    }
    return nodes;
  }

  void _processNode({
    required Map<int, ModelNode> nodes,
    required ModelNode? parent,
    required GltfRef<Node> nodeRef,
  }) {
    final gltfNode = nodeRef.get();

    final mesh = gltfNode.mesh?.get().toFlameMesh(null, gltfNode.weights);

    final skin = gltfNode.skin?.get();
    final inverseBindMatrices = skin?.inverseBindMatrices?.get().typedData();
    final joints = skin?.joints ?? [];

    final modelJoints = <int, ModelJoint>{};
    for (final (i, joint) in joints.indexed) {
      modelJoints[i] = ModelJoint(
        nodeIndex: joint.index,
        inverseBindMatrix:
            inverseBindMatrices?.elementAt(i) ?? Matrix4.identity(),
      );
    }

    final node = ModelNode(
      name: gltfNode.name,
      nodeIndex: nodeRef.index,
      parentNodeIndex: parent?.nodeIndex,
      transform: gltfNode.transform,
      mesh: mesh,
      joints: modelJoints,
    );
    nodes[nodeRef.index] = node;

    for (final child in gltfNode.children) {
      _processNode(
        nodes: nodes,
        parent: node,
        nodeRef: child,
      );
    }
  }
}
