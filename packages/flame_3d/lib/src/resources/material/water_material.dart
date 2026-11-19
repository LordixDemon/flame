import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// {@template water_material}
/// Animated 4-wave Gerstner GPU water material with scrolling micro-ripples,
/// shallow/deep color gradient, crest foam, a Fresnel blend towards a flat sky
/// color (the hemisphere light's sky, or the ambient light), directional,
/// point and spot light glints, directional PCF shadow reception, Grab-Pass
/// underwater screen-space refraction, and [FogSettings].
///
/// Works in both `+Y`-up (`upAxis: Vector3(0, 1, 0)`) and `+Z`-up
/// (`upAxis: Vector3(0, 0, 1)`) worlds: the waves and the ripples are built
/// around [upAxis]. Advance [time] each frame to animate.
///
/// The [renderState] follows [opacity]: alpha blended below `1`, opaque at
/// `1` (both culling back faces), unless a render state was set by hand.
/// {@endtemplate}
class WaterMaterial({
  var Color shallowColor = const Color(0xFF38BDF8),
  var Color deepColor = const Color(0xFF0F3460),
  var Color foamColor = const Color(0xE6F8FAFC),
  var double time = 0.0,
  var double waveAmplitude = 0.08,
  var double waveFrequency = 1.6,
  var double waveSpeed = 1.8,
  var double steepness = 0.45,
  Vector3? upAxis,
  var double rippleStrength = 0.08,
  var double rippleScale = 0.85,
  var double foamThreshold = 0.68,
  var double fresnelPower = 3.2,
  var double specularStrength = 0.85,
  var double specularPower = 48.0,
  double opacity = 0.86,

  /// Clip-depth thickness span (`> 0` generates shoreline intersection foam
  /// where opaque scene geometry meets the water surface when
  /// `World3D.depthPrepassEnabled` is active).
  var double shoreFoamDepth = 0.0,

  /// Screen-UV offset multiplier applied when `World3D.grabSceneColorEnabled`
  /// refracts opaque underwater geometry.
  var double refractionStrength = 0.04,
}) extends Material {
  /// {@macro water_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: [RenderContext3D.cameraMatricesBlock, 'WaterVertex'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: [
            'WaterMaterial',
            RenderContext3D.stylizedPassBlock,
            RenderContext3D.shadowMapSampler,
            RenderContext3D.depthNormalSampler,
            RenderContext3D.depthNormalBlock,
            RenderContext3D.sceneColorSampler,
            RenderContext3D.sceneColorBlock,
          ],
        ),
      ) {
    castsShadows = false;
    renderState = _derivedState = _stateFor(opacity);
  }

  /// The opacity of the water body, `0..1` (foam and grazing angles add to
  /// it). Below `1` the water is alpha blended.
  double get opacity => _opacity;
  double _opacity = opacity;
  set opacity(double value) {
    _opacity = value;
    if (identical(renderState, _derivedState)) {
      renderState = _derivedState = _stateFor(value);
    }
  }

  RenderState? _derivedState;

  static RenderState _stateFor(double opacity) => opacity < 1.0
      ? _translucentState
      : const RenderState(cullMode: CullMode.backFace);

  static final RenderState _translucentState = RenderState.alphaBlend.copyWith(
    cullMode: CullMode.backFace,
  );

  static const String _bundle =
      'packages/flame_3d/assets/shaders/water_material.shaderbundle';

  /// World up axis perpendicular to the rest water surface.
  Vector3 upAxis = upAxis?.clone() ?? Vector3(0, 1, 0);

  static final Vector4 _waveParams = Vector4.zero();
  static final Vector4 _upSteep = Vector4.zero();
  static final Vector4 _fragParams = Vector4.zero();
  static final Vector4 _fragParams2 = Vector4.zero();
  static final Vector4 _shoreVec = Vector4.zero();
  static final Vector4 _upVec = Vector4.zero();

  @override
  void apply(RenderContext context) {
    vertexShader
      ..setVector4(
        'WaterVertex.waveParams',
        _waveParams..setValues(time, waveAmplitude, waveFrequency, waveSpeed),
      )
      ..setVector4(
        'WaterVertex.upAndSteepness',
        _upSteep..setValues(upAxis.x, upAxis.y, upAxis.z, steepness),
      );

    fragmentShader
      ..setColor('WaterMaterial.shallowColor', shallowColor)
      ..setColor('WaterMaterial.deepColor', deepColor)
      ..setColor('WaterMaterial.foamColor', foamColor)
      ..setVector4(
        'WaterMaterial.params',
        _fragParams..setValues(
          time,
          rippleStrength,
          foamThreshold,
          specularPower,
        ),
      )
      ..setVector4(
        'WaterMaterial.params2',
        _fragParams2..setValues(
          fresnelPower,
          specularStrength,
          opacity,
          rippleScale,
        ),
      )
      ..setVector4(
        'WaterMaterial.shoreParams',
        _shoreVec..setValues(shoreFoamDepth, refractionStrength, 0, 0),
      )
      ..setVector4(
        'WaterMaterial.upAxis',
        _upVec..setValues(upAxis.x, upAxis.y, upAxis.z, 0),
      );
  }
}
