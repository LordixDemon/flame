import 'dart:ui';

import 'package:flame/game.dart' show Game;
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/material_pipeline_cache.dart';
import 'package:meta/meta.dart';

/// {@template material}
/// Base material: the shaders a surface is drawn with, the values it binds to
/// them, and the [renderState] it is drawn with.
///
/// The [RenderContext3D] links the shaders into a pipeline for the vertex
/// layout of each surface the material draws, and caches it.
///
/// ## Instancing
///
/// When the vertex shader declares the per-instance inputs of
/// `shaders/flame_3d/instancing.glsl` (the model matrix columns, and
/// optionally `instanceColor`), the draws of one surface with the same
/// material are batched into instanced draws, and [apply] runs once each time
/// the material is bound. Otherwise every object is drawn on its own and
/// [apply] runs before each draw, with [RenderContext3D.model] set to its
/// model matrix.
/// {@endtemplate}
abstract class Material({
  required var Shader _vertexShader,
  required var Shader _fragmentShader,
}) {
  /// Checks that the device can run the material's shaders, see
  /// [Shader.checkDeviceSupport]: a material the device cannot draw throws
  /// an [UnsupportedError] here rather than drawing nothing.
  this {
    _vertexShader.checkDeviceSupport(owner: runtimeType);
    _fragmentShader.checkDeviceSupport(owner: runtimeType);
  }

  static Material defaultMaterial = SpatialMaterial()
    ..albedoColor = const Color(0xFFFF00FF);

  static int _nextId = 0;

  /// A number identifying this material, used to group draws by material.
  final int id = _nextId++;

  Shader get vertexShader => _vertexShader;
  set vertexShader(Shader shader) {
    _vertexShader = shader;
    pipelineCache = null;
  }

  Shader get fragmentShader => _fragmentShader;
  set fragmentShader(Shader shader) {
    _fragmentShader = shader;
    pipelineCache = null;
  }

  /// The blending, depth and culling state this material draws with, and
  /// whether it is translucent. Defaults to [RenderState.opaque].
  ///
  /// For example, a material for glows that are added to what is behind them:
  ///
  /// ```dart
  /// material.renderState = RenderState.additive;
  /// ```
  ///
  /// or an opaque material that culls back faces:
  ///
  /// ```dart
  /// material.renderState = const RenderState(cullMode: CullMode.backFace);
  /// ```
  RenderState renderState = RenderState.opaque;

  /// The depth prepass this material's draws share, when its [renderState]
  /// is translucent with [RenderState.depthPrepass]: `null` (the default)
  /// for a prepass of their own (or of their mesh).
  ///
  /// The draws of every material with an identical non-null key, in a render
  /// pass, are ordered together among the translucent draws, all write their
  /// depth first, and are then shaded with [CompareFunction.lessEqual]: where
  /// several overlap on screen, only the nearest is shaded. See
  /// `ShadowCatcherMaterial.nearestOnly`.
  Object? depthPrepassGroup;

  /// Whether the surfaces drawn with this material cast shadows (see
  /// [ShadowSettings]).
  ///
  /// By default opaque materials do and translucent ones (see
  /// [RenderState.translucent]: glass, glows, additive effects) do not. Set
  /// it to override that, for instance to `false` for an opaque glow, and to
  /// `null` to go back to the default.
  ///
  /// A caster's shadow is rendered from its positions alone (skinned when
  /// its vertices have joints and joint weights): vertices that a material's
  /// own vertex shader moves (`StylizedMaterial`'s wind, for instance)
  /// cast the shadow of their rest position.
  ///
  /// Changing it marks the shadow casters of every `World3D` dirty (see
  /// `World3D.castersVersion`), since a material can be drawn in any world.
  bool get castsShadows => _castsShadows ?? !renderState.translucent;
  set castsShadows(bool? value) {
    if (value == _castsShadows) {
      return;
    }
    _castsShadows = value;
    _castsShadowsRevision++;
    Game.notifyVisualMutation();
  }

  bool? _castsShadows;

  static int _castsShadowsRevision = 0;

  /// The number of times the [castsShadows] of a material changed, added to
  /// the versions of every `World3D`.
  @internal
  static int get castsShadowsRevision => _castsShadowsRevision;

  /// The layer of this material's translucent draws: translucent draws are
  /// drawn in increasing order of it, and back to front within one order.
  ///
  /// `0` by default. A surface that lies under the other translucent things
  /// of a scene, whatever their distance (a water surface under splashes and
  /// mist, a translucent ground under particles), takes a lower order, `-1`,
  /// so that it is drawn first and they blend over it, rather than being
  /// sorted by the centers of their bounds. Opaque draws ignore it; under
  /// `OitMode3D.weightedBlended` translucent draws are not sorted at all.
  int translucentOrder = 0;

  /// Whether the per-instance inputs of this material's draws hold model
  /// matrices (`instanceModel0` to `instanceModel3`), as `drawSurface` and
  /// `InstancedGroup3D` write them.
  ///
  /// Materials whose vertex shader reads other data from those inputs
  /// (camera-facing billboards and particles store a center and a size)
  /// return `false`, so passes that draw the positions with a generic shader
  /// (the depth-normal prepass) leave their draws out instead of drawing
  /// stray triangles.
  bool get instancesHoldModelMatrices => true;

  /// Whether the draws of this material read the `ReflectionProbeVolume3D`
  /// around them, `false` unless overridden.
  ///
  /// When it is `true` and the world has volumes, the [RenderContext3D]
  /// chooses a volume for each draw as it is recorded, keeps draws with
  /// different volumes in separate batches, and sets
  /// [RenderContext3D.reflectionProbe] and
  /// [RenderContext3D.reflectionProbeWeight] before [apply].
  bool get usesReflectionProbes => false;

  /// The pipeline this material drew with last, managed by the
  /// [RenderContext3D].
  @internal
  MaterialPipelineCache? pipelineCache;

  /// The vertex shader that draws surfaces whose vertices are laid out as
  /// [layout]: [vertexShader] unless overridden.
  ///
  /// A material can draw several vertex layouts by overriding it to return a
  /// vertex shader variant per layout. Every variant must feed the
  /// [fragmentShader] the same outputs; [apply] writes the values of all of
  /// them, as it does not know which one is bound.
  Shader vertexShaderFor(VertexLayout layout) => vertexShader;

  /// The material that draws this material's surfaces in the depth-normal
  /// prepass ([RenderContext3D.isDepthNormalPass]), or `null` (the default)
  /// for the prepass's own shaders.
  ///
  /// The prepass's own shaders place each vertex with the instance model
  /// matrix and cover the whole surface. A material whose vertex shader
  /// reads the instance inputs as other data (billboards do), or that
  /// discards pixels (an alpha cutoff), returns a material whose vertex
  /// shader places the vertices the same way, reading the instance inputs,
  /// and whose fragment shader discards the same pixels and writes the
  /// prepass's encoding (`encodeDepthNormal` of
  /// `#include <flame_3d/depth_normal_encoding.glsl>`).
  /// The prepass draws only the surfaces of opaque materials that write
  /// depth; a material that has a depth-normal material is drawn with it
  /// even when [instancesHoldModelMatrices] is `false`.
  Material? get depthNormalMaterial => null;

  /// Writes this material's values into its shaders, see [Material].
  ///
  /// Uniform blocks filled by the [RenderContext3D] (see
  /// [RenderContext3D.registerPassUniform]) and the joint matrices of skinned
  /// draws need not be written.
  void apply(RenderContext context) {}
}
