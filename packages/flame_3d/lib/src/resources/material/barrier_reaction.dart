part of 'barrier_material.dart';

/// The second material of a [BarrierMaterial] with
/// [BarrierMaterial.reactionInFront]: the same shaders, drawing the reaction
/// only, where something in front of the wall hid it.
class _BarrierReactionMaterial(final BarrierMaterial _source) extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          BarrierMaterial._fullBundle,
          slots: const [RenderContext3D.cameraMatricesBlock, 'BarrierShape'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          BarrierMaterial._fullBundle,
          slots: const ['BarrierLook'],
        ),
      ) {
    setInitialState(castsShadows: false);
  }

  /// The changes of this material and of its source, whose values it draws.
  @override
  int get version => super.version + _source.version;

  RenderState? _sourceState;

  /// Follows the source's render state and translucent order.
  void _sync() {
    translucentOrder = _source.translucentOrder;
    final state = _source.renderState;
    if (identical(state, _sourceState)) {
      return;
    }
    _sourceState = state;
    renderState = state.copyWith(
      depthTest: true,
      depthCompare: CompareFunction.greater,
      depthWrite: false,
      depthPrepass: false,
      translucent: true,
    );
  }

  int _appliedVersion = -1;
  Shader? _appliedVert;
  int _appliedVertGen = -1;
  Shader? _appliedFrag;
  int _appliedFragGen = -1;
  RenderContext? _appliedContext;
  int _appliedCameraPass = -1;

  @override
  bool get hasPassStableFragmentShader => true;

  @override
  bool get cachesApply => true;

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
        identical(_appliedFrag, fragmentShader) &&
        _appliedFragGen == fragmentShader.generation &&
        identical(_appliedContext, context) &&
        context is RenderContext3D &&
        _appliedCameraPass == context.cameraPass;
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
    _appliedFrag = fragmentShader;
    _appliedFragGen = fragmentShader.generation;
    _appliedContext = context;
    if (context is RenderContext3D) {
      _appliedCameraPass = context.cameraPass;
    }
  }

  @override
  void apply(RenderContext context) {
    _source._write(
      this,
      context as RenderContext3D,
      _source.reactionInFront.clamp(0.0, 1.0),
    );
  }
}
