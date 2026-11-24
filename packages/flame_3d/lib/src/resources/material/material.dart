import 'dart:ui';

import 'package:flame/game.dart' show Game;
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
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
///
/// ## Changes
///
/// A material reports its own changes: every setter of a material, and of
/// the state objects it reads (its palettes, `WaterRipples`,
/// `WaterFoamSources`, ...), raises its [version] when the value written
/// differs from the one held, and wakes idle-throttled game loops. A world
/// keeps the versions of the materials it drew in its last render, so that
/// a retained layer (`Scene3DCacheMode.retained`) renders again when one of
/// them changed and reuses its image otherwise, see `World3D.sceneVersion`.
/// Writing the value already held costs nothing.
///
/// The fields a material reads every frame by design, the time of its
/// animation (`WaterMaterial.time`, `BarrierMaterial.time`,
/// `StylizedMaterial.windTime`), raise the version too: writing one every
/// frame is how a material says that it animates, and the layers that draw
/// it render every frame (counted in `RenderStats.animatedMaterials`);
/// leaving it alone holds the material still, and its layers keep their
/// images. What the setters cannot see (a texture whose contents are
/// rendered again, values a subclass's [apply] computes from a clock of its
/// own) is reported with [markChanged], or with [animated] when it changes
/// on every frame.
///
/// No field of a material moves a shadow besides [castsShadows] (and the
/// [renderState] it defaults to): the shadow passes draw positions only, so
/// a change of a material's version keeps the cached shadow maps.
/// {@endtemplate}
abstract class Material({
  required var Shader _vertexShader,
  required var Shader _fragmentShader,
}) with Versioned {
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
    if (identical(shader, _vertexShader)) {
      return;
    }
    _vertexShader = shader;
    pipelineCache = null;
    invalidateApplyCache();
    markChanged();
  }

  Shader get fragmentShader => _fragmentShader;
  set fragmentShader(Shader shader) {
    if (identical(shader, _fragmentShader)) {
      return;
    }
    _fragmentShader = shader;
    pipelineCache = null;
    invalidateApplyCache();
    markChanged();
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
  ///
  /// Assigning a state that changes whether it is translucent, while
  /// [castsShadows] follows it, marks the shadow casters of every `World3D`
  /// dirty, as assigning [castsShadows] does, once a pass has drawn the
  /// material (until then, no shadow map holds it).
  RenderState get renderState => _renderState;
  set renderState(RenderState value) {
    if (value == _renderState) {
      return;
    }
    final casts = castsShadows;
    _renderState = value;
    if (castsShadows != casts && wasRecorded) {
      _castsShadowsRevision++;
    }
    markChanged();
  }

  RenderState _renderState = RenderState.opaque;

  /// Sets the [renderState] and [castsShadows] of a material being created,
  /// which no world has drawn yet, those given: unlike their setters, it
  /// reports no change and leaves the cached shadow maps of the worlds
  /// alone.
  @protected
  void setInitialState({RenderState? renderState, bool? castsShadows}) {
    if (renderState != null) {
      _renderState = renderState;
    }
    if (castsShadows != null) {
      _castsShadows = castsShadows;
    }
  }

  /// The depth prepass this material's draws share, when its [renderState]
  /// is translucent with [RenderState.depthPrepass]: `null` (the default)
  /// for a prepass of their own (or of their mesh).
  ///
  /// The draws of every material with an identical non-null key, in a render
  /// pass, are ordered together among the translucent draws, all write their
  /// depth first, and are then shaded with [CompareFunction.lessEqual]: where
  /// several overlap on screen, only the nearest is shaded. See
  /// `ShadowCatcherMaterial.nearestOnly`.
  Object? get depthPrepassGroup => _depthPrepassGroup;
  set depthPrepassGroup(Object? value) =>
      _depthPrepassGroup = noteChange(_depthPrepassGroup, value);
  Object? _depthPrepassGroup;

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

  static int _assignmentRevision = 0;

  /// The number of times a surface was given another material, added to
  /// the scene versions of every `World3D`.
  @internal
  static int get assignmentRevision => _assignmentRevision;

  /// Reports that a surface was given another material, which casts
  /// differently when [shadows].
  @internal
  static void noteAssignment({required bool shadows}) {
    _assignmentRevision++;
    if (shadows) {
      _castsShadowsRevision++;
    }
    Game.notifyVisualMutation();
  }

  /// The layer of this material's translucent draws: translucent draws are
  /// drawn in increasing order of it, and back to front within one order.
  ///
  /// `0` by default. A surface that lies under the other translucent things
  /// of a scene, whatever their distance (a water surface under splashes and
  /// mist, a translucent ground under particles), takes a lower order, `-1`,
  /// so that it is drawn first and they blend over it, rather than being
  /// sorted by the centers of their bounds. Opaque draws ignore it; under
  /// `OitMode3D.weightedBlended` translucent draws are not sorted at all.
  int get translucentOrder => _translucentOrder;
  set translucentOrder(int value) =>
      _translucentOrder = noteChange(_translucentOrder, value);
  int _translucentOrder = 0;

  /// Whether this material changes on every frame in ways its setters do
  /// not report, `false` by default: a subclass whose [apply] computes its
  /// values from a clock of its own, a texture whose contents are rendered
  /// again every frame.
  ///
  /// While a world draws an animated material, it counts as changed on
  /// every frame: the retained layers that show it render every frame, the
  /// game loop keeps rendering while it updates (it does not idle), and
  /// each render counts it in `RenderStats.animatedMaterials`. The built-in
  /// materials need not be marked: they animate through the time a game
  /// advances (`WaterMaterial.time`, for instance), whose writes they report
  /// themselves. A change that happens once is reported with [markChanged].
  bool get animated => _animated;
  set animated(bool value) => _animated = noteChange(_animated, value);
  bool _animated = false;

  /// Returns [next], having reported a change when it differs from
  /// [current], for the setters of the time of a material's animation (see
  /// [Material]): like [noteChange], and counted as an animation by
  /// `RenderStats.animatedMaterials`.
  @protected
  double noteTime(double current, double next) {
    if (current != next) {
      _animationVersion++;
      markChanged();
    }
    return next;
  }

  /// The number of changes of the time of this material's animation (see
  /// [noteTime]), part of [version].
  @internal
  int get animationVersion => _animationVersion;
  int _animationVersion = 0;

  /// The mark of the last render that noted this material, managed by the
  /// world that drew it.
  @internal
  int trackingStamp = 0;

  /// Whether a render pass has recorded a draw of this material (a main
  /// pass, which made its pipeline, or a shadow pass), managed by the render
  /// context.
  @internal
  bool wasRecorded = false;

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

  /// Whether draws using this material are treated as dynamic for
  /// `StaticSceneCache3D` (for example translucent or animated materials).
  bool get isStaticCacheDynamic => renderState.translucent || animated;

  /// Whether a draw of [surface] using this material is dynamic for
  /// `StaticSceneCache3D` (when the material is dynamic or [surface] carries
  /// per-vertex shader animation that this material drives).
  bool isStaticCacheDynamicForSurface(Surface surface) => isStaticCacheDynamic;

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
  Object? pipelineCache;

  /// The vertex shader that draws surfaces whose vertices are laid out as
  /// [layout]: [vertexShader] unless overridden.
  ///
  /// A material can draw several vertex layouts by overriding it to return a
  /// vertex shader variant per layout. Every variant must feed the
  /// [fragmentShader] the same outputs; [apply] writes the values of all of
  /// them, as it does not know which one is bound.
  Shader vertexShaderFor(VertexLayout layout) => vertexShader;

  /// The fragment shader that draws surfaces laid out as [layout] within
  /// [context]: [fragmentShader] unless overridden.
  ///
  /// Materials that offer a leaner fragment variant when optional features
  /// are inactive for the active pass can override this to select it without
  /// altering [fragmentShader].
  Shader fragmentShaderFor(RenderContext3D context, VertexLayout layout) =>
      fragmentShader;

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

  /// Whether [fragmentShaderFor] returns the same shader for every draw of a
  /// single pass (`RenderContext3D._pass`), letting `_resolvePipeline` skip the
  /// virtual lookup on a cache hit within the same pass.
  @internal
  bool get hasPassStableFragmentShader => false;

  /// Whether repeated draws of this material with identical tracked inputs can
  /// reuse previously written shader uniform blocks and samplers instead of
  /// calling [apply] again.
  ///
  /// Built-in materials return `runtimeType == ExactClass` so subclasses
  /// overriding [apply] continue to execute on every draw.
  @internal
  bool get cachesApply => false;

  /// Whether shader values written by a prior [apply] are still current for
  /// [vertexShader], [fragmentShader], and [context].
  @internal
  bool isApplyCacheValid(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => false;

  /// Records that [apply] populated [vertexShader] and [fragmentShader] for the
  /// current material state and [context].
  @internal
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) {}

  /// Drops any cached [apply] state.
  @protected
  void invalidateApplyCache() {}

  /// Visits every GPU [Texture] referenced by this material (for resource
  /// ownership tracking and disposal in asset scopes).
  void visitTextures(void Function(Texture texture) visitor) {}

  /// Writes this material's values into its shaders, see [Material].
  ///
  /// Uniform blocks filled by the [RenderContext3D] (see
  /// [RenderContext3D.registerPassUniform]) and the joint matrices of skinned
  /// draws need not be written.
  void apply(RenderContext context) {}
}
