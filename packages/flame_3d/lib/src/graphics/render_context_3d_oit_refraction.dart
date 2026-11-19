part of 'render_context_3d.dart';

/// Scene Color Grab-Pass and McGuire & Bavoil Weighted Blended OIT
/// (`OitMode3D.weightedBlended`) passes for [RenderContext3D].
class _OitAndGrabPass(final RenderContext3D _context) {
  bool grabActive = false;
  Texture? grabTexture;
  int grabWidth = 1;
  int grabHeight = 1;

  static const String _wboitAccumBundle =
      'packages/flame_3d/assets/shaders/wboit_accum.shaderbundle';
  static const String _wboitCompositeBundle =
      'packages/flame_3d/assets/shaders/wboit_composite.shaderbundle';

  static final Surface _fullscreenQuad = Surface.fromBuffers(
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

  late final Shader _wboitVert = VertexShader.fromAsset(
    _wboitAccumBundle,
    slots: [RenderContext3D.cameraMatricesBlock],
  );
  late final Shader _wboitFrag = FragmentShader.fromAsset(
    _wboitAccumBundle,
    slots: const ['albedoTexture', 'WboitMaterial'],
  );

  late final Shader _compVert = VertexShader.fromAsset(_wboitCompositeBundle);
  late final Shader _compFrag = FragmentShader.fromAsset(
    _wboitCompositeBundle,
    slots: const ['opaqueTexture', 'accumTexture', 'revealTexture'],
  );

  final Map<VertexLayout, DevicePipeline?> _wboitPipelines = Map.identity();
  final Vector4 _wboitBaseColor = Vector4.zero();
  final Vector4 _wboitParams = Vector4.zero();

  void setGrabTarget(GpuTextureTarget? target) {
    if (target == null) {
      grabActive = false;
      grabTexture = null;
      return;
    }
    grabActive = true;
    grabWidth = target.width;
    grabHeight = target.height;
    grabTexture = Texture(
      null,
      width: target.width,
      height: target.height,
      sampler: TextureSampler.linear,
      gpuTexture: target.texture,
    );
  }

  void clearGrab() {
    grabActive = false;
  }

  /// Submits all currently recorded translucent draws in Weighted Blended OIT
  /// mode (`revealPass == false` -> accumulation pass, `revealPass == true` ->
  /// revealage product pass), after writing opaque caster depths so opaque
  /// surfaces occlude translucent fragments accurately.
  void flushWboitSubpass({
    required bool revealPass,
    required bool releaseAfter,
  }) {
    final context = _context;
    final device = context.device;
    final count = context._count;

    // 1. Write opaque geometry depths into this pass's depth attachment so
    //    translucent fragments behind opaque walls are rejected by `less`.
    var opaqueCount = 0;
    for (var i = 0; i < count; i++) {
      final mat = context._materials[i]!;
      if (!mat.renderState.translucent && mat.renderState.depthWrite) {
        context._opaque[opaqueCount++] = i;
        context._groupKeys[i] = context._pipelines[i]!.id.toDouble();
        context._surfaceKeys[i] =
            context._surfaces[i]!.id * 2 + (context._joints[i] == null ? 0 : 1);
        context._sortDepths[i] = context._depths[i];
      }
    }
    context._sort(context._opaque, opaqueCount);
    context._boundMaterial = null;
    context._bindingEpoch = -1;
    context._depthPrepassOverride = true;
    context._submitBatches(context._opaque, opaqueCount);
    context._depthPrepassOverride = false;

    // 2. Submit every translucent draw in recording order (order-independent!).
    final blendState = revealPass
        ? const RenderState(
            blend: BlendState.wboitReveal,
            depthWrite: false,
          )
        : const RenderState(
            blend: BlendState.wboitAccum,
            depthWrite: false,
          );

    var cameraBoundEpoch = -1;
    for (var i = 0; i < count; i++) {
      final mat = context._materials[i]!;
      if (!mat.renderState.translucent) {
        continue;
      }
      final surface = context._surfaces[i]!;
      final pipeline = _wboitPipelineFor(surface.layout);
      if (pipeline == null) {
        continue;
      }

      device.bindPipeline(pipeline);
      if (device.bindingEpoch != cameraBoundEpoch) {
        cameraBoundEpoch = device.bindingEpoch;
        context._bindSlots(_wboitVert, RenderContext3D._passScope);
      }

      final state = blendState.copyWith(
        cullMode: mat.renderState.cullMode,
        depthTest: mat.renderState.depthTest,
      );
      device
        ..setRenderState(state)
        ..setFrontFace(
          (context._mirrored[i] == 1) == context._isMirrored
              ? WindingOrder.counterClockwise
              : WindingOrder.clockwise,
        );

      final (col, tex, uScale, vScale) = _extractTranslucentAppearance(mat);
      _wboitBaseColor.setValues(col.r, col.g, col.b, col.a);
      _wboitParams.setValues(revealPass ? 1.0 : 0.0, uScale, vScale, 0.0);
      _wboitFrag
        ..setTexture('albedoTexture', tex)
        ..setVector4('WboitMaterial.baseColor', _wboitBaseColor)
        ..setVector4('WboitMaterial.params', _wboitParams);

      device
        ..bindTexture(_wboitFrag.slot('albedoTexture'), tex)
        ..bindUniformBlock(_wboitFrag.block('WboitMaterial'))
        ..bindSurface(surface);

      final external = context._external[i];
      if (external != null) {
        final instCount = context._externalCounts[i];
        device
          ..bindInstances(external, instCount)
          ..drawSurface(surface, instanceCount: instCount);
      } else {
        context._translucent[0] = i;
        device
          ..bindInstancesOf(context._instances, context._translucent, 0, 1)
          ..drawSurface(surface);
      }
    }

    if (releaseAfter) {
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
  }

  DevicePipeline? _wboitPipelineFor(VertexLayout layout) {
    if (_wboitPipelines.containsKey(layout)) {
      return _wboitPipelines[layout];
    }
    if (layout.attribute(VertexLayout.positionAttribute)?.components != 3 ||
        layout.attribute('vertexTexCoord')?.components != 2 ||
        layout.attribute('vertexColor')?.components != 4) {
      return _wboitPipelines[layout] = null;
    }
    _wboitVert.resource;
    _wboitFrag.resource;
    return _wboitPipelines[layout] = _context.device.pipelineFor(
      _wboitVert,
      _wboitFrag,
      layout,
    );
  }

  static (Color, Texture, double, double) _extractTranslucentAppearance(
    Material mat,
  ) {
    if (mat is SpatialMaterial) {
      return (
        mat.albedoColor,
        mat.albedoTexture,
        mat.uvScale.x,
        mat.uvScale.y,
      );
    }
    if (mat is UnlitMaterial) {
      return (mat.albedoColor, mat.albedoTexture, 1.0, 1.0);
    }
    if (mat is WaterMaterial) {
      final c = mat.shallowColor;
      return (
        Color.from(alpha: mat.opacity, red: c.r, green: c.g, blue: c.b),
        Texture.standard,
        1.0,
        1.0,
      );
    }
    return (const Color(0x80FFFFFF), Texture.standard, 1.0, 1.0);
  }

  /// Draws the full-screen WBOIT composition quad into the currently open pass.
  void drawCompositeQuad({
    required GpuTextureTarget opaqueTarget,
    required GpuTextureTarget accumTarget,
    required GpuTextureTarget revealTarget,
  }) {
    final device = _context.device;
    final opaqueTex = Texture(
      null,
      width: opaqueTarget.width,
      height: opaqueTarget.height,
      sampler: TextureSampler.linear,
      gpuTexture: opaqueTarget.texture,
    );
    final accumTex = Texture(
      null,
      width: accumTarget.width,
      height: accumTarget.height,
      sampler: TextureSampler.linear,
      gpuTexture: accumTarget.texture,
    );
    final revealTex = Texture(
      null,
      width: revealTarget.width,
      height: revealTarget.height,
      sampler: TextureSampler.linear,
      gpuTexture: revealTarget.texture,
    );

    _compVert.resource;
    _compFrag
      ..resource
      ..setTexture('opaqueTexture', opaqueTex)
      ..setTexture('accumTexture', accumTex)
      ..setTexture('revealTexture', revealTex);

    final pipeline = device.pipelineFor(
      _compVert,
      _compFrag,
      _fullscreenQuad.layout,
    );
    device
      ..bindPipeline(pipeline)
      ..setRenderState(
        const RenderState(depthTest: false, depthWrite: false),
      )
      ..bindTexture(_compFrag.slot('opaqueTexture'), opaqueTex)
      ..bindTexture(_compFrag.slot('accumTexture'), accumTex)
      ..bindTexture(_compFrag.slot('revealTexture'), revealTex)
      ..bindSurface(_fullscreenQuad)
      ..drawSurface(_fullscreenQuad);
  }

  static final Vector4 _scratchSceneColor = Vector4.zero();

  static void writeSceneColorUniforms(
    RenderContext3D context,
    UniformBlock block,
  ) {
    final g = context._oitGrab;
    block.setVector4(
      'params',
      _scratchSceneColor..setValues(
        g.grabActive ? 1.0 : 0.0,
        1.0 / g.grabWidth,
        1.0 / g.grabHeight,
        0.0,
      ),
    );
  }

  static Texture sceneColorPassTexture(RenderContext3D context) {
    final g = context._oitGrab;
    return g.grabActive ? g.grabTexture! : Texture.standard;
  }
}
