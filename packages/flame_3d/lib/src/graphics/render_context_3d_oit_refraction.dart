part of 'render_context_3d.dart';

/// Scene Color Grab-Pass and order-independent transparency
/// (`OitMode3D.weightedBlended`) passes for [RenderContext3D].
///
/// Order-independent transparency draws every alpha-blended translucent draw
/// with its own material twice: into an accumulation target, adding up the
/// premultiplied colors and the alphas (`sum(C * a)`, `sum(a)`), and into a
/// revealage target, multiplying `1 - a` (`prod(1 - a)`). The composite then
/// lays the average color `sum(C * a) / sum(a)` over the opaque image with a
/// coverage of `1 - prod(1 - a)`: a weighted average (McGuire and Bavoil's
/// weighted blended transparency with a constant weight), exact for one layer
/// and independent of the order of the draws. Translucent draws with another
/// blend (additive, depth-only) are drawn after the composite, sorted.
class _OitAndGrabPass(final RenderContext3D _context) {
  bool grabActive = false;
  Texture? grabTexture;
  int grabWidth = 1;
  int grabHeight = 1;

  /// The values of `RenderContext3D._oitPass`.
  static const int noPass = 0;
  static const int accumulationPass = 1;
  static const int revealagePass = 2;

  static const String _wboitCompositeBundle =
      'packages/flame_3d/assets/shaders/wboit_composite.shaderbundle';

  late final Shader _compVert = VertexShader.fromAsset(_wboitCompositeBundle);
  late final Shader _compFrag = FragmentShader.fromAsset(
    _wboitCompositeBundle,
    slots: const ['opaqueTexture', 'accumTexture', 'revealTexture'],
  );

  // The textures of the targets last composited, rebuilt when they change.
  final List<GpuTextureTarget?> _compositeTargets = List.filled(3, null);
  final List<Texture> _compositeTextures = List.filled(3, Texture.standard);
  DevicePipeline? _compPipeline;
  int _compVertGen = -1;
  int _compFragGen = -1;
  GpuUniformSlot? _opaqueSlot;
  GpuUniformSlot? _accumSlot;
  GpuUniformSlot? _revealSlot;

  static final Map<RenderState, RenderState> _accumulationStates = {};
  static final Map<RenderState, RenderState> _revealageStates = {};

  /// Whether translucent draws with [state] are accumulated by the
  /// order-independent passes (alpha blended), rather than drawn sorted after
  /// the composite.
  static bool accumulates(RenderState state) {
    return state.translucent &&
        (state.blend == BlendState.alpha ||
            state.blend == BlendState.premultipliedAlpha);
  }

  /// The render state a draw of [state] is submitted with in [pass].
  static RenderState stateFor(RenderState state, int pass) {
    if (pass == revealagePass) {
      return _revealageStates[state] ??= state.copyWith(
        blend: BlendState.wboitReveal,
        depthWrite: false,
      );
    }
    return _accumulationStates[state] ??= state.copyWith(
      blend: state.blend == BlendState.alpha
          ? BlendState.wboitAccumStraight
          : BlendState.wboitAccum,
      depthWrite: false,
    );
  }

  void setGrabTarget(GpuTextureTarget? target) {
    if (target == null) {
      grabActive = false;
      grabTexture = null;
      return;
    }
    grabActive = true;
    grabWidth = target.width;
    grabHeight = target.height;
    final texture = grabTexture;
    if (texture == null || !identical(texture.gpuTexture, target.texture)) {
      grabTexture = Texture(
        null,
        width: target.width,
        height: target.height,
        sampler: TextureSampler.linear,
        gpuTexture: target.texture,
      );
    }
  }

  void clearGrab() {
    grabActive = false;
  }

  int _opaqueDepthSortedCount = -1;
  int _wboitSortedCount = -1;

  bool get hasSortCache =>
      _opaqueDepthSortedCount >= 0 || _wboitSortedCount >= 0;

  void resetOpaqueDepthCache() {
    _opaqueDepthSortedCount = -1;
  }

  void resetSortCache() {
    _opaqueDepthSortedCount = -1;
    _wboitSortedCount = -1;
  }

  /// Draws the opaque draws that write depth into the open pass, depth only,
  /// so that they hide the translucent fragments behind them.
  void _drawOpaqueDepth() {
    final context = _context;
    var opaqueCount = _opaqueDepthSortedCount;
    if (opaqueCount < 0) {
      context._cachedOpaqueCount = -1;
      final count = context._count;
      opaqueCount = 0;
      for (var i = 0; i < count; i++) {
        final mat = context._materials[i]!;
        if (!mat.renderState.translucent && mat.renderState.depthWrite) {
          context._opaque[opaqueCount++] = i;
          context._groupKeys[i] = context._pipelines[i]!.id.toDouble();
          context._surfaceKeys[i] =
              context._surfaces[i]!.id * 2 +
              (context._joints[i] == null ? 0 : 1);
          context._sortDepths[i] = context._depths[i];
        }
      }
      context._sortByProbe = false;
      context._sort(context._opaque, opaqueCount);
      _opaqueDepthSortedCount = opaqueCount;
    }
    context._boundMaterial = null;
    context._bindingEpoch = -1;
    context._depthPrepassOverride = true;
    context._submitBatches(context._opaque, opaqueCount);
    context._depthPrepassOverride = false;
  }

  /// Submits the recorded alpha-blended translucent draws with their own
  /// materials into the accumulation (`revealPass == false`) or revealage
  /// (`revealPass == true`) target of the open pass, after the depths of the
  /// opaque draws.
  void flushWboitSubpass({
    required bool revealPass,
    required bool releaseAfter,
  }) {
    final context = _context;
    final count = context._count;

    _drawOpaqueDepth();

    // The draws are summed (or multiplied), so their order does not matter:
    // they are grouped to batch as opaque draws are.
    final order = context._translucent;
    var oitCount = _wboitSortedCount;
    if (oitCount < 0) {
      oitCount = 0;
      for (var i = 0; i < count; i++) {
        final material = context._materials[i]!;
        if (accumulates(material.renderState)) {
          order[oitCount++] = i;
          context._groupKeys[i] =
              context._pipelines[i]!.id * 8589934592.0 +
              material.id * 2.0 +
              context._mirrored[i];
          context._surfaceKeys[i] =
              context._surfaces[i]!.id * 2 +
              (context._joints[i] == null ? 0 : 1);
          context._sortDepths[i] = context._depths[i];
        }
      }
      context._sortByProbe = false;
      context._sort(order, oitCount);
      _wboitSortedCount = oitCount;
    }
    context._boundMaterial = null;
    context._bindingEpoch = -1;
    context._oitPass = revealPass ? revealagePass : accumulationPass;
    try {
      context._submitBatches(order, oitCount);
    } finally {
      context._oitPass = noPass;
    }

    if (releaseAfter) {
      _release();
    }
  }

  void _release() {
    final context = _context;
    final count = context._count;
    context
      .._releaseDraws(count)
      .._boundMaterial = null
      .._jointTransforms = null
      .._lastDrawCount = count
      .._count = 0
      .._nextPrepassGroupId = 1
      .._activePrepassGroup = 0
      .._prepassGroupNesting = 0;
  }

  Texture _textureOf(int index, GpuTextureTarget target) {
    if (!identical(_compositeTargets[index], target)) {
      _compositeTargets[index] = target;
      _compositeTextures[index] = Texture(
        null,
        width: target.width,
        height: target.height,
        sampler: TextureSampler.linear,
        gpuTexture: target.texture,
      );
    }
    return _compositeTextures[index];
  }

  /// Draws the composite of [opaqueTarget], [accumTarget] and [revealTarget]
  /// into the open pass, then the recorded translucent draws that are not
  /// accumulated (additive and other blends), sorted back to front and
  /// depth tested against the opaque draws (drawn again, depth only), and
  /// releases the recorded draws.
  void drawCompositeQuad({
    required GpuTextureTarget opaqueTarget,
    required GpuTextureTarget accumTarget,
    required GpuTextureTarget revealTarget,
  }) {
    final context = _context;
    final device = context.device;
    final count = context._count;

    final order = context._translucent;
    _wboitSortedCount = -1;
    var sortedCount = 0;
    for (var i = 0; i < count; i++) {
      final state = context._materials[i]!.renderState;
      if (state.translucent && !accumulates(state)) {
        order[sortedCount++] = i;
        context._groupKeys[i] = 0;
        context._surfaceKeys[i] = 0;
        context._sortDepths[i] = -context._depths[i];
      }
    }

    final opaqueTex = _textureOf(0, opaqueTarget);
    final accumTex = _textureOf(1, accumTarget);
    final revealTex = _textureOf(2, revealTarget);
    _compVert.resource;
    _compFrag.resource;
    var pipeline = _compPipeline;
    if (pipeline == null ||
        _compVertGen != _compVert.generation ||
        _compFragGen != _compFrag.generation) {
      pipeline = _compPipeline = device.pipelineFor(
        _compVert,
        _compFrag,
        fullscreenQuadSurface.layout,
      );
      _compVertGen = _compVert.generation;
      _compFragGen = _compFrag.generation;
      _opaqueSlot = _compFrag.slot('opaqueTexture');
      _accumSlot = _compFrag.slot('accumTexture');
      _revealSlot = _compFrag.slot('revealTexture');
    }
    device
      ..bindPipeline(pipeline)
      ..setRenderState(_compositeState)
      ..bindTexture(_opaqueSlot!, opaqueTex)
      ..bindTexture(_accumSlot!, accumTex)
      ..bindTexture(_revealSlot!, revealTex)
      ..bindSurface(fullscreenQuadSurface)
      ..drawSurface(fullscreenQuadSurface);

    if (sortedCount > 0) {
      _drawOpaqueDepth();
      context._sortByProbe = false;
      context._sort(order, sortedCount);
      context._boundMaterial = null;
      context._bindingEpoch = -1;
      context._submitTranslucentBatches(order, sortedCount);
    }
    _release();
  }

  static const RenderState _compositeState = RenderState(
    depthTest: false,
    depthWrite: false,
  );

  static void writeSceneColorUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final g = context._oitGrab;
    final off =
        (block.cachedWriterOffsets as int?) ??
        (block.cachedWriterOffsets = block.resolveOffset('params'));
    if (off >= 0) {
      block.writeVec4ValuesAt(
        off,
        g.grabActive ? 1.0 : 0.0,
        1.0 / g.grabWidth,
        1.0 / g.grabHeight,
        0.0,
      );
    }
  }

  static Texture sceneColorPassTexture(RenderContext3D context) {
    final g = context._oitGrab;
    return g.grabActive ? g.grabTexture! : Texture.standard;
  }
}
