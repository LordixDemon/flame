import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Material rendered by [SkyboxComponent3D] at clip depth `1.0` behind all
/// opaque geometry.
class SkyboxMaterial3D({
  var Color _zenithColor = const Color(0xFF0F2952),
  var Color _horizonColor = const Color(0xFF5BA4CF),
  var Color _groundColor = const Color(0xFF1E293B),
  var Color _sunColor = const Color(0xFFFFF3C4),
  var double _sunIntensity = 1.25,
  Vector3? sunDirection,
  var double _sunAngularRadius = 0.045,
  var double _sunHaloStrength = 0.35,
  var double _horizonExponent = 0.55,
  var double _exposure = 1.0,
  Vector3? upAxis,
  var Texture? _panoramaTexture,
}) extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(_bundle),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: const ['panoramaTexture', 'Skybox'],
        ),
      ) {
    setInitialState(
      renderState: const RenderState(
        depthCompare: CompareFunction.lessEqual,
        depthWrite: false,
      ),
      castsShadows: false,
    );
    _sunDirection.addListener(markChanged);
    _upAxis.addListener(markChanged);
  }

  Color get zenithColor => _zenithColor;
  set zenithColor(Color value) =>
      _zenithColor = noteChange(_zenithColor, value);

  Color get horizonColor => _horizonColor;
  set horizonColor(Color value) =>
      _horizonColor = noteChange(_horizonColor, value);

  Color get groundColor => _groundColor;
  set groundColor(Color value) =>
      _groundColor = noteChange(_groundColor, value);

  Color get sunColor => _sunColor;
  set sunColor(Color value) => _sunColor = noteChange(_sunColor, value);

  double get sunIntensity => _sunIntensity;
  set sunIntensity(double value) =>
      _sunIntensity = noteChange(_sunIntensity, value);

  double get sunAngularRadius => _sunAngularRadius;
  set sunAngularRadius(double value) =>
      _sunAngularRadius = noteChange(_sunAngularRadius, value);

  double get sunHaloStrength => _sunHaloStrength;
  set sunHaloStrength(double value) =>
      _sunHaloStrength = noteChange(_sunHaloStrength, value);

  double get horizonExponent => _horizonExponent;
  set horizonExponent(double value) =>
      _horizonExponent = noteChange(_horizonExponent, value);

  double get exposure => _exposure;
  set exposure(double value) => _exposure = noteChange(_exposure, value);

  Texture? get panoramaTexture => _panoramaTexture;
  set panoramaTexture(Texture? value) =>
      _panoramaTexture = noteChange(_panoramaTexture, value);

  static const String _bundle =
      'packages/flame_3d/assets/shaders/skybox_material.shaderbundle';

  /// Direction light travels FROM the sun (`-sunDir` points towards the sun),
  /// matching [DirectionalLight.direction]. Assigning a vector copies it;
  /// changing it in place counts as a change ([version]).
  Vector3 get sunDirection => _sunDirection;
  set sunDirection(Vector3 value) => _sunDirection.setFrom(value);
  final NotifyingVector3 _sunDirection = NotifyingVector3.copy(
    sunDirection ?? Vector3(-0.45, -0.65, -0.6),
  );

  /// World up axis (`(0, 1, 0)` by default). Assigning a vector copies it;
  /// changing it in place counts as a change ([version]).
  Vector3 get upAxis => _upAxis;
  set upAxis(Vector3 value) => _upAxis.setFrom(value);
  final NotifyingVector3 _upAxis = NotifyingVector3.copy(
    upAxis ?? Vector3(0, 1, 0),
  );

  static final Matrix4 _rotOnlyView = Matrix4.identity();
  static final Matrix4 _invVp = Matrix4.identity();
  static final Vector3 _toSun = Vector3.zero();
  static final Vector4 _sunColorVec = Vector4.zero();
  static final Vector4 _sunDirVec = Vector4.zero();
  static final Vector4 _upModeVec = Vector4.zero();
  static final Vector4 _paramsVec = Vector4.zero();

  @override
  void apply(RenderContext context) {
    final ctx3d = context as RenderContext3D;
    // Strip camera translation so the sky remains infinitely far away.
    _rotOnlyView
      ..setFrom(ctx3d.view)
      ..setTranslationRaw(0, 0, 0);
    _invVp
      ..setFrom(ctx3d.projection)
      ..multiply(_rotOnlyView);
    final det = _invVp.invert();
    if (det == 0.0) {
      _invVp.setIdentity();
    }

    _toSun
      ..setFrom(sunDirection)
      ..scale(-1.0);
    if (_toSun.length2 > 1e-12) {
      _toSun.normalize();
    } else {
      _toSun.setValues(0, 1, 0);
    }

    final pano = panoramaTexture;
    fragmentShader
      ..setTexture('panoramaTexture', pano ?? Texture.standard)
      ..setMatrix4('Skybox.invViewProjection', _invVp)
      ..setColor('Skybox.zenithColor', zenithColor)
      ..setColor('Skybox.horizonColor', horizonColor)
      ..setColor('Skybox.groundColor', groundColor)
      ..setVector4(
        'Skybox.sunColor',
        _sunColorVec..setValues(
          sunColor.r,
          sunColor.g,
          sunColor.b,
          sunIntensity,
        ),
      )
      ..setVector4(
        'Skybox.sunDir',
        _sunDirVec..setValues(
          _toSun.x,
          _toSun.y,
          _toSun.z,
          math.cos(sunAngularRadius.clamp(0.001, 0.5)),
        ),
      )
      ..setVector4(
        'Skybox.upAndMode',
        _upModeVec..setValues(
          upAxis.x,
          upAxis.y,
          upAxis.z,
          pano != null ? 1.0 : 0.0,
        ),
      )
      ..setVector4(
        'Skybox.params',
        _paramsVec..setValues(
          horizonExponent,
          sunHaloStrength,
          exposure,
          0,
        ),
      );
  }
}

/// Renders an atmospheric gradient + sun sky (or equirectangular panorama) in a
/// `World3D` at clip depth `1.0` with zero overdraw on covered pixels.
class SkyboxComponent3D({
  SkyboxMaterial3D? material,
}) extends Object3D {
  this : super(castsShadows: false);

  final SkyboxMaterial3D material = material ?? SkyboxMaterial3D();

  static final Surface _clipQuad = Surface.fromBuffers(
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

  static final Aabb3 _skyBounds = Aabb3.minMax(
    Vector3.all(-0.01),
    Vector3.all(0.01),
  );

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == SkyboxComponent3D;

  @override
  Aabb3? computeLocalAabb() => _skyBounds;

  @override
  void draw(covariant RenderContext3D context) {
    if (context.isShadowPass) {
      return;
    }
    context.drawSurface(_clipQuad, material: material);
  }
}
