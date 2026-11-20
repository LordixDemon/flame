import 'dart:math' as math;
import 'dart:typed_data';
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
///
/// ## Clear, shallow water without extra passes
///
/// Its options draw clear water with one translucent draw and neither the
/// depth prepass nor the scene color grab; all of them are off by default:
///
/// - [causticStrength]: an animated network of light in [causticColor], of
///   [causticScale] world units, that never visibly repeats;
/// - [sparkleStrength]: tiny points that flash in the light, one per cell of
///   [sparkleScale] world units;
/// - [detailStrength]: a gentle swell of the normals, waves of up to
///   [detailScale] world units, whose highlights of the sun and of the lamps
///   move over the water;
/// - [depthRange]: the color goes from [shallowColor] to [deepColor] and the
///   opacity from [shallowOpacity] to [opacity] with the depth of the water
///   under each vertex, `1 - exp(-depth / depthRange)` of the way, and the
///   water is more opaque at grazing angles;
/// - foam where the vertices of a surface in [vertexLayout] say (against a
///   wall, around a rock), with lapping edges broken up into patches of
///   [edgeFoamScale] world units;
/// - [ripples]: rings that spread from where things land on, rise out of or
///   move through the water, see [WaterRipples].
///
/// The caustics, the sparkles, the swell and the edge foam loop over
/// [animationPeriod] seconds of [time]. Surfaces in [vertexLayout] (built
/// with [buildSurface]) give each vertex the depth of the water under it,
/// its foam mask and its calm (which stills the waves near a wall); surfaces
/// in the standard layout are [defaultDepth] deep everywhere, without foam
/// mask.
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

  /// The strength of the caustic network, the bright, wavy lines of light
  /// a rippled surface focuses: `0` (the default) turns it off, `1` adds
  /// [causticColor] times the light reaching the water on the lines.
  var double causticStrength = 0,

  /// The size of the cells of the caustic network, in world units, on
  /// average.
  var double causticScale = 0.6,

  /// The color of the caustic network, times the light reaching the water.
  var Color causticColor = const Color(0xFFFFFFFF),

  /// The strength of the sparkles, tiny points that flash in the light of
  /// the lights reaching the water: `0` (the default) turns them off.
  var double sparkleStrength = 0,

  /// The size of the cells of the sparkles, in world units: one point
  /// flashes in each cell, twice per [animationPeriod].
  var double sparkleScale = 0.35,

  /// How much a gentle swell of small waves tilts the normals, so that the
  /// highlights of the lights move over the water: `0` (the default) turns
  /// it off, `1` tilts them by about 0.3 radians at most.
  var double detailStrength = 0,

  /// The length of the longest wave of the swell of [detailStrength], in
  /// world units.
  var double detailScale = 1.6,

  /// The period, in seconds of [time], over which the caustics, the
  /// sparkles, the swell and the edge foam loop exactly.
  var double animationPeriod = 8,

  /// The depth of the water, in world units, over which the color goes
  /// from [shallowColor] to [deepColor] and the opacity from
  /// [shallowOpacity] to [opacity]: `1 - exp(-depth / depthRange)` of the
  /// way. `0` (the default) turns the ramp off: the color then follows the
  /// height of the waves, and the opacity is [opacity].
  var double depthRange = 0,

  /// The opacity of the water where it has no depth, with [depthRange].
  var double shallowOpacity = 0.2,

  /// The depth of the water under the vertices of surfaces in the standard
  /// layout, which do not say it, for [depthRange].
  var double defaultDepth = 1,

  /// The size of the patches the edge foam breaks into, in world units.
  var double edgeFoamScale = 0.6,

  /// The ripples this water draws, shared with the other materials of the
  /// same body of water; `null` (the default) draws none.
  var WaterRipples? ripples,
}) extends Material {
  /// {@macro water_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: [RenderContext3D.cameraMatricesBlock, _vertexBlock],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: [
            _fragmentBlock,
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

  static const String _vertexBlock = 'WaterVertex';
  static const String _fragmentBlock = 'WaterMaterial';

  /// World up axis perpendicular to the rest water surface.
  Vector3 upAxis = upAxis?.clone() ?? Vector3(0, 1, 0);

  /// The name of the attribute of [vertexLayout] that tells, per vertex, the
  /// depth of the water under it, its foam mask and its calm.
  static const String waterAttribute = 'vertexWater';

  /// The vertex layout of water surfaces that say, per vertex, how deep the
  /// water is under them, where they foam and where the waves calm down,
  /// 10 floats per vertex:
  ///
  /// | Attribute        | Floats | Meaning                                  |
  /// | ---------------- | ------ | ---------------------------------------- |
  /// | `vertexPosition` | 3      | the position                             |
  /// | `vertexColor`    | 4      | multiplies the color (rgb) and opacity   |
  /// | `vertexWater`    | 3      | depth (world units), foam mask, calm     |
  ///
  /// The depth drives [depthRange]; the foam mask, from `0` to `1`, draws
  /// foam (a band, lapping and broken up, that is solid towards `1`); the
  /// calm, from `0` (the full waves) to `1` (still), scales the waves down,
  /// for vertices against a wall. Build surfaces in it with [buildSurface].
  static final VertexLayout vertexLayout = VertexLayout(const [
    VertexAttribute(VertexLayout.positionAttribute, 3),
    VertexAttribute('vertexColor', 4),
    VertexAttribute(waterAttribute, 3),
  ]);

  // The variant for surfaces in [vertexLayout].
  final Shader _maskedVertexShader = VertexShader.fromAsset(
    'packages/flame_3d/assets/shaders/water_material_masked.shaderbundle',
    slots: [RenderContext3D.cameraMatricesBlock, _vertexBlock],
  );

  // Whether the masked variant drew: only then are its values written.
  bool _maskedInUse = false;

  VertexLayout? _lastLayout;
  Shader? _lastShader;

  @override
  Shader vertexShaderFor(VertexLayout layout) {
    if (!identical(layout, _lastLayout)) {
      _lastLayout = layout;
      if (layout.offsetOf(waterAttribute) != null) {
        _lastShader = _maskedVertexShader;
        _maskedInUse = true;
      } else {
        _lastShader = vertexShader;
      }
    }
    return _lastShader!;
  }

  static final Vector4 _waveParams = Vector4.zero();
  static final Vector4 _upSteep = Vector4.zero();
  static final Vector4 _surface = Vector4.zero();
  static final Vector4 _fragParams = Vector4.zero();
  static final Vector4 _fragParams2 = Vector4.zero();
  static final Vector4 _shoreVec = Vector4.zero();
  static final Vector4 _upVec = Vector4.zero();
  static final Vector4 _pattern = Vector4.zero();
  static final Vector4 _detail = Vector4.zero();
  static final Vector4 _ramp = Vector4.zero();
  static final Vector3 _up = Vector3.zero();
  static final Vector3 _uAxis = Vector3.zero();
  static final Vector3 _vAxis = Vector3.zero();
  static final Vector3 _cross = Vector3.zero();
  static final Vector4 _causticColor = Vector4.zero();
  static final List<Vector4> _ripplePositions = List.generate(
    WaterRipples.capacity,
    (_) => Vector4.zero(),
  );
  static final List<Vector4> _rippleShapes = List.generate(
    WaterRipples.capacity,
    (_) => Vector4.zero(),
  );

  @override
  void apply(RenderContext context) {
    _applyVertex(vertexShader);
    if (_maskedInUse) {
      _applyVertex(_maskedVertexShader);
    }

    // The members of the options are written through the block, which
    // ignores members a shader does not have (the shaders of before, in
    // tests).
    final block = fragmentShader.block(_fragmentBlock)
      ..setColor('shallowColor', shallowColor)
      ..setColor('deepColor', deepColor)
      ..setColor('foamColor', foamColor)
      ..setVector4(
        'params',
        _fragParams..setValues(
          time,
          rippleStrength,
          foamThreshold,
          specularPower,
        ),
      )
      ..setVector4(
        'params2',
        _fragParams2..setValues(
          fresnelPower,
          specularStrength,
          opacity,
          rippleScale,
        ),
      )
      ..setVector4(
        'shoreParams',
        _shoreVec..setValues(shoreFoamDepth, refractionStrength, 0, 0),
      )
      ..setVector4(
        'upAxis',
        _upVec..setValues(upAxis.x, upAxis.y, upAxis.z, 0),
      );
    if (!block.hasMember('pattern')) {
      return;
    }

    var rippleCount = 0;
    final ripples = this.ripples;
    if (ripples != null) {
      _planeAxes(upAxis);
      rippleCount = ripples.writeUniforms(
        time,
        _uAxis,
        _vAxis,
        _ripplePositions,
        _rippleShapes,
      );
      for (var i = 0; i < rippleCount; i++) {
        block
          ..setVector4('ripplePositions', _ripplePositions[i], index: i)
          ..setVector4('rippleShapes', _rippleShapes[i], index: i);
      }
    }
    final caustics = math.max(0.0, causticStrength);
    final sparkles = math.max(0.0, sparkleStrength);
    final addsLight = caustics > 0 || sparkles > 0 || rippleCount > 0;
    block
      ..setVector4(
        'causticColor',
        _causticColor..setValues(
          causticColor.r,
          causticColor.g,
          causticColor.b,
          caustics,
        ),
      )
      ..setVector4(
        'pattern',
        _pattern..setValues(
          patternPhase(time, animationPeriod),
          _inverse(causticScale),
          sparkles,
          _inverse(sparkleScale),
        ),
      )
      ..setVector4(
        'detail',
        _detail..setValues(
          math.max(0.0, detailStrength),
          _inverse(detailScale),
          _inverse(edgeFoamScale),
          addsLight ? 1 : 0,
        ),
      )
      ..setVector4(
        'ramp',
        _ramp..setValues(
          depthRange > 0 ? 1 / depthRange : 0,
          shallowOpacity,
          0,
          rippleCount.toDouble(),
        ),
      );
  }

  void _applyVertex(Shader shader) {
    shader.block(_vertexBlock)
      ..setVector4(
        'waveParams',
        _waveParams..setValues(time, waveAmplitude, waveFrequency, waveSpeed),
      )
      ..setVector4(
        'upAndSteepness',
        _upSteep..setValues(upAxis.x, upAxis.y, upAxis.z, steepness),
      )
      ..setVector4('surface', _surface..setValues(defaultDepth, 0, 0, 0));
  }

  /// The phase of [time] in a loop of [period] seconds, from `0` to `2π`:
  /// `2π * fract(time / period)`, `0` when [period] is not positive. The
  /// patterns of the options move with whole multiples of it, so that they
  /// loop exactly over the period, and wrapping the time on the CPU keeps
  /// the shader's arguments small however long the game runs.
  static double patternPhase(double time, double period) {
    if (!(period > 0) || !time.isFinite) {
      return 0;
    }
    final turns = time / period;
    return (turns - turns.floorToDouble()) * 2 * math.pi;
  }

  static double _inverse(double scale) => scale > 0 ? 1 / scale : 0;

  /// Sets [_uAxis] and [_vAxis] to the plane axes the shaders build around
  /// [up] (see `flame_3d/water_vertex.glsl`).
  static void _planeAxes(Vector3 up) {
    _up.setFrom(up);
    if (_up.length2 == 0) {
      _up.setValues(0, 1, 0);
    }
    _up.normalize();
    if (_up.y.abs() < 0.9) {
      _uAxis.setValues(0, 1, 0);
    } else {
      _uAxis.setValues(1, 0, 0);
    }
    // uAxis = normalize(cross(ref, up)), vAxis = normalize(cross(up, uAxis)).
    _uAxis
      ..crossInto(_up, _cross)
      ..setFrom(_cross)
      ..normalize();
    _up.crossInto(_uAxis, _vAxis);
    _vAxis.normalize();
  }

  /// Builds a surface in [vertexLayout] from per-vertex arrays, drawn with
  /// [material].
  ///
  /// [positions] hold 3 floats per vertex and [colors] 4 (RGBA, white by
  /// default); [depths] (the depth of the water under each vertex, in world
  /// units, `0` by default), [foam] (the foam mask, `0` by default) and
  /// [calm] (`0`, the full waves, by default) one each. [indices] are the
  /// triangles' vertex indices.
  static Surface buildSurface({
    required List<double> positions,
    required List<int> indices,
    required Material material,
    List<double>? colors,
    List<double>? depths,
    List<double>? foam,
    List<double>? calm,
    Aabb3? aabb,
  }) {
    final count = positions.length ~/ 3;
    void check(List<double>? values, String name, int perVertex) {
      if (values != null && values.length != count * perVertex) {
        throw ArgumentError.value(
          values.length,
          name,
          'Must hold $perVertex float(s) for each of the $count vertices',
        );
      }
    }

    check(positions, 'positions', 3);
    check(colors, 'colors', 4);
    check(depths, 'depths', 1);
    check(foam, 'foam', 1);
    check(calm, 'calm', 1);
    const stride = 10;
    final data = Float32List(count * stride);
    for (var i = 0; i < count; i++) {
      final o = i * stride;
      data
        ..[o] = positions[i * 3]
        ..[o + 1] = positions[i * 3 + 1]
        ..[o + 2] = positions[i * 3 + 2]
        ..[o + 3] = colors == null ? 1 : colors[i * 4]
        ..[o + 4] = colors == null ? 1 : colors[i * 4 + 1]
        ..[o + 5] = colors == null ? 1 : colors[i * 4 + 2]
        ..[o + 6] = colors == null ? 1 : colors[i * 4 + 3]
        ..[o + 7] = depths?[i] ?? 0
        ..[o + 8] = foam?[i] ?? 0
        ..[o + 9] = calm?[i] ?? 0;
    }
    var wide = count > 0xFFFF;
    for (var i = 0; !wide && i < indices.length; i++) {
      wide = indices[i] >= 0xFFFF;
    }
    final List<int> indexList;
    if (indices is Uint16List || indices is Uint32List) {
      indexList = indices;
    } else if (wide) {
      indexList = Uint32List.fromList(indices);
    } else {
      indexList = Uint16List.fromList(indices);
    }
    return Surface.fromBuffers(
      vertices: data,
      indices: indexList,
      layout: vertexLayout,
      material: material,
      aabb: aabb,
    );
  }
}
