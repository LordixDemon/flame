import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/game.dart';
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
///   [edgeFoamScale] world units, that [edgeFoamMotion] slows down or holds
///   still;
/// - [ripples]: rings that spread from where things land on, rise out of or
///   move through the water, see [WaterRipples];
/// - [foamSources]: collars of the same foam around the things that stand in
///   the water or move through it, set and moved at run time, see
///   [WaterFoamSources];
/// - [foamLightTint]: how much of the color of the light the foam of the
///   foam mask, of the foam sources and of the ripples takes (`1`, the
///   default, all of it; less keeps the foam white under a colored sun);
/// - [foamLightFloor]: the least light that foam takes (`0.5`, the default,
///   half its color; more keeps it bright in low light, at dusk).
///
/// The caustics, the sparkles, the swell and the edge foam loop over
/// [animationPeriod] seconds of [time]. Surfaces in [vertexLayout] (built
/// with [buildSurface]) give each vertex the depth of the water under it,
/// its foam mask and its calm (which stills the waves near a wall); surfaces
/// in the standard layout are [defaultDepth] deep everywhere, without foam
/// mask.
/// {@endtemplate}
class WaterMaterial({
  var Color _shallowColor = const Color(0xFF38BDF8),
  var Color _deepColor = const Color(0xFF0F3460),
  var Color _foamColor = const Color(0xE6F8FAFC),
  var double _time = 0.0,
  var double _waveAmplitude = 0.08,
  var double _waveFrequency = 1.6,
  var double _waveSpeed = 1.8,
  var double _steepness = 0.45,
  Vector3? upAxis,
  var double _rippleStrength = 0.08,
  var double _rippleScale = 0.85,
  var double _foamThreshold = 0.68,
  var double _fresnelPower = 3.2,
  var double _specularStrength = 0.85,
  var double _specularPower = 48.0,
  double opacity = 0.86,
  var double _shoreFoamDepth = 0.0,
  var double _refractionStrength = 0.04,
  var double _causticStrength = 0,
  var double _causticScale = 0.6,
  var Color _causticColor = const Color(0xFFFFFFFF),
  var double _sparkleStrength = 0,
  var double _sparkleScale = 0.35,
  var double _detailStrength = 0,
  var double _detailScale = 1.6,
  var double _animationPeriod = 8,
  var double _depthRange = 0,
  var double _shallowOpacity = 0.2,
  var double _defaultDepth = 1,
  var double _edgeFoamScale = 0.6,
  var WaterRipples? _ripples,
  var double _foamLightTint = 1,
  var double _foamLightFloor = 0.5,
  var double _edgeFoamMotion = 1,
  var WaterFoamSources? _foamSources,
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
          slots: _fragmentSlots,
        ),
      ) {
    _leanFragment = super.fragmentShader;
    setInitialState(
      renderState: _derivedState = _stateFor(opacity),
      castsShadows: false,
    );
    _upAxis.addListener(markChanged);
  }

  /// The changes of this material, of its [ripples] and of its
  /// [foamSources]: adding a ripple or moving a foam source changes it.
  @override
  int get version =>
      super.version + (_ripples?.version ?? 0) + (_foamSources?.version ?? 0);

  /// The ripples this water draws, shared with the other materials of the
  /// same body of water; `null` (the default) draws none.
  WaterRipples? get ripples => _ripples;
  set ripples(WaterRipples? value) {
    if (identical(value, _ripples)) {
      return;
    }
    final before = version;
    _ripples = value;
    markReplaced(before);
  }

  /// The foam sources this water draws, collars of foam around the things
  /// that move, shared with the other materials of the same body of water;
  /// `null` (the default) draws none.
  ///
  /// The material draws with a lean fragment stage, whose 8 slots of foam
  /// sources draw collars whose pattern stays in the world, and switches to
  /// its full stage, 16 slots that can carry their pattern, 16 uniform
  /// vectors larger and a little slower everywhere, while its set holds more
  /// than 8 sources ([WaterFoamSources.capacity]) or one of them carries its
  /// pattern ([WaterFoamSources.setCarryPattern]); unless its
  /// [fragmentShader] was replaced by another one.
  ///
  /// The changes of the set count as changes of this material ([version]).
  WaterFoamSources? get foamSources => _foamSources;
  set foamSources(WaterFoamSources? value) {
    if (identical(value, _foamSources)) {
      return;
    }
    final before = version;
    _foamSources = value;
    markReplaced(before);
  }

  Color get shallowColor => _shallowColor;
  set shallowColor(Color value) =>
      _shallowColor = noteChange(_shallowColor, value);

  Color get deepColor => _deepColor;
  set deepColor(Color value) => _deepColor = noteChange(_deepColor, value);

  Color get foamColor => _foamColor;
  set foamColor(Color value) => _foamColor = noteChange(_foamColor, value);

  /// The time of the waves and of the patterns, in seconds: advance it
  /// every frame to animate the water (see [Material] on how the layers
  /// that draw it follow it).
  double get time => _time;
  set time(double value) => _time = noteTime(_time, value);

  double get waveAmplitude => _waveAmplitude;
  set waveAmplitude(double value) =>
      _waveAmplitude = noteChange(_waveAmplitude, value);

  double get waveFrequency => _waveFrequency;
  set waveFrequency(double value) =>
      _waveFrequency = noteChange(_waveFrequency, value);

  double get waveSpeed => _waveSpeed;
  set waveSpeed(double value) => _waveSpeed = noteChange(_waveSpeed, value);

  double get steepness => _steepness;
  set steepness(double value) => _steepness = noteChange(_steepness, value);

  double get rippleStrength => _rippleStrength;
  set rippleStrength(double value) =>
      _rippleStrength = noteChange(_rippleStrength, value);

  double get rippleScale => _rippleScale;
  set rippleScale(double value) =>
      _rippleScale = noteChange(_rippleScale, value);

  double get foamThreshold => _foamThreshold;
  set foamThreshold(double value) =>
      _foamThreshold = noteChange(_foamThreshold, value);

  double get fresnelPower => _fresnelPower;
  set fresnelPower(double value) =>
      _fresnelPower = noteChange(_fresnelPower, value);

  double get specularStrength => _specularStrength;
  set specularStrength(double value) =>
      _specularStrength = noteChange(_specularStrength, value);

  double get specularPower => _specularPower;
  set specularPower(double value) =>
      _specularPower = noteChange(_specularPower, value);

  /// Clip-depth thickness span (`> 0` generates shoreline intersection foam
  /// where opaque scene geometry meets the water surface when
  /// `World3D.depthPrepassEnabled` is active).
  double get shoreFoamDepth => _shoreFoamDepth;
  set shoreFoamDepth(double value) =>
      _shoreFoamDepth = noteChange(_shoreFoamDepth, value);

  /// Screen-UV offset multiplier applied when `World3D.grabSceneColorEnabled`
  /// refracts opaque underwater geometry.
  double get refractionStrength => _refractionStrength;
  set refractionStrength(double value) =>
      _refractionStrength = noteChange(_refractionStrength, value);

  /// The strength of the caustic network, the bright, wavy lines of light
  /// a rippled surface focuses: `0` (the default) turns it off, `1` adds
  /// [causticColor] times the light reaching the water on the lines.
  double get causticStrength => _causticStrength;
  set causticStrength(double value) =>
      _causticStrength = noteChange(_causticStrength, value);

  /// The size of the cells of the caustic network, in world units, on
  /// average.
  double get causticScale => _causticScale;
  set causticScale(double value) =>
      _causticScale = noteChange(_causticScale, value);

  /// The color of the caustic network, times the light reaching the water.
  Color get causticColor => _causticColor;
  set causticColor(Color value) =>
      _causticColor = noteChange(_causticColor, value);

  /// The strength of the sparkles, tiny points that flash in the light of
  /// the lights reaching the water: `0` (the default) turns them off.
  double get sparkleStrength => _sparkleStrength;
  set sparkleStrength(double value) =>
      _sparkleStrength = noteChange(_sparkleStrength, value);

  /// The size of the cells of the sparkles, in world units: one point
  /// flashes in each cell, twice per [animationPeriod].
  double get sparkleScale => _sparkleScale;
  set sparkleScale(double value) =>
      _sparkleScale = noteChange(_sparkleScale, value);

  /// How much a gentle swell of small waves tilts the normals, so that the
  /// highlights of the lights move over the water: `0` (the default) turns
  /// it off, `1` tilts them by about 0.3 radians at most.
  double get detailStrength => _detailStrength;
  set detailStrength(double value) =>
      _detailStrength = noteChange(_detailStrength, value);

  /// The length of the longest wave of the swell of [detailStrength], in
  /// world units.
  double get detailScale => _detailScale;
  set detailScale(double value) =>
      _detailScale = noteChange(_detailScale, value);

  /// The period, in seconds of [time], over which the caustics, the
  /// sparkles, the swell and the edge foam loop exactly.
  double get animationPeriod => _animationPeriod;
  set animationPeriod(double value) =>
      _animationPeriod = noteChange(_animationPeriod, value);

  /// The depth of the water, in world units, over which the color goes
  /// from [shallowColor] to [deepColor] and the opacity from
  /// [shallowOpacity] to [opacity]: `1 - exp(-depth / depthRange)` of the
  /// way. `0` (the default) turns the ramp off: the color then follows the
  /// height of the waves, and the opacity is [opacity].
  double get depthRange => _depthRange;
  set depthRange(double value) => _depthRange = noteChange(_depthRange, value);

  /// The opacity of the water where it has no depth, with [depthRange].
  double get shallowOpacity => _shallowOpacity;
  set shallowOpacity(double value) =>
      _shallowOpacity = noteChange(_shallowOpacity, value);

  /// The depth of the water under the vertices of surfaces in the standard
  /// layout, which do not say it, for [depthRange].
  double get defaultDepth => _defaultDepth;
  set defaultDepth(double value) =>
      _defaultDepth = noteChange(_defaultDepth, value);

  /// The size of the patches the edge foam breaks into, in world units.
  double get edgeFoamScale => _edgeFoamScale;
  set edgeFoamScale(double value) =>
      _edgeFoamScale = noteChange(_edgeFoamScale, value);

  /// How much of the color of the light the lit foam takes (the foam of the
  /// foam mask, of the [foamSources] and of the [ripples]), from `0` to `1`:
  /// `1` (the default) takes the color of the light as it is, `0` only its
  /// brightness (its luminance), so the foam keeps [foamColor] under a
  /// colored light. About `0.25` suits a low, warm sun. The crest and shore
  /// foam are not lit and keep [foamColor] anyway.
  double get foamLightTint => _foamLightTint;
  set foamLightTint(double value) =>
      _foamLightTint = noteChange(_foamLightTint, value);

  /// The least light the lit foam takes (the foam of the foam mask, of the
  /// [foamSources] and of the [ripples]), as a multiple of [foamColor], `0`
  /// or more: the light reaching the water is clamped between it and
  /// `1.15` (or it, when it is above). `0.5` (the default) lets the foam
  /// fall to half its color in low light, where it turns grey against
  /// lighter water; at dusk about `0.85` keeps white foam bright, with
  /// [foamLightTint] about `0.25`. Above about `1` the foam no longer
  /// darkens in shadow either. The crest and shore foam are not lit.
  double get foamLightFloor => _foamLightFloor;
  set foamLightFloor(double value) =>
      _foamLightFloor = noteChange(_foamLightFloor, value);

  /// How fast the foam of the foam mask and of the [foamSources] laps and
  /// drifts, as a multiple of its own pace: `1` (the default) laps twice per
  /// [animationPeriod], `0` holds it still (a rim of ice along a wall, dried
  /// salt, a painted edge), still broken up into patches but not moving. The
  /// caustics, the sparkles, the swell and the ripples keep their pace.
  double get edgeFoamMotion => _edgeFoamMotion;
  set edgeFoamMotion(double value) =>
      _edgeFoamMotion = noteChange(_edgeFoamMotion, value);

  /// The fragment stage this material draws with: the lean or the full one
  /// that its [foamSources] need (see [foamSources]), or the one it was
  /// given.
  @override
  Shader get fragmentShader {
    _chooseFragment();
    return super.fragmentShader;
  }

  static const List<String> _fragmentSlots = [
    _fragmentBlock,
    RenderContext3D.stylizedPassBlock,
    RenderContext3D.shadowMapSampler,
    RenderContext3D.lightGridSampler,
    RenderContext3D.depthNormalSampler,
    RenderContext3D.depthNormalBlock,
    RenderContext3D.sceneColorSampler,
    RenderContext3D.sceneColorBlock,
  ];

  /// The number of slots of foam sources of the lean fragment stage.
  static const int _leanSlots = 8;

  // The lean fragment stage, and the full one, made when a set needs it.
  late final Shader _leanFragment;
  Shader? _fullFragment;

  // The set and the version of it the stage was chosen for.
  WaterFoamSources? _chosenFor;
  int _chosenVersion = -1;

  /// Draws with the fragment stage [foamSources] need (see [foamSources]),
  /// unless the fragment shader was replaced by another one. Checks the set
  /// again only when it, or its version, changed.
  void _chooseFragment() {
    final sources = foamSources;
    final version = sources?.version ?? -1;
    if (identical(sources, _chosenFor) && version == _chosenVersion) {
      return;
    }
    _chosenFor = sources;
    _chosenVersion = version;
    final current = super.fragmentShader;
    if (!identical(current, _leanFragment) &&
        !identical(current, _fullFragment)) {
      return;
    }
    final full =
        sources != null &&
        (sources.capacity > _leanSlots || sources.carriesAnyPattern);
    final next = full
        ? (_fullFragment ??= FragmentShader.fromAsset(
            _maskedBundle,
            slots: _fragmentSlots,
          ))
        : _leanFragment;
    if (!identical(next, current)) {
      fragmentShader = next;
    }
  }

  /// The opacity of the water body, `0..1` (foam and grazing angles add to
  /// it). Below `1` the water is alpha blended.
  double get opacity => _opacity;
  double _opacity = opacity;
  set opacity(double value) {
    if (value == _opacity) {
      return;
    }
    _opacity = value;
    if (identical(renderState, _derivedState)) {
      renderState = _derivedState = _stateFor(value);
    }
    markChanged();
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

  /// World up axis perpendicular to the rest water surface. Assigning a
  /// vector copies it; changing it in place counts as a change ([version]).
  Vector3 get upAxis => _upAxis;
  set upAxis(Vector3 value) => _upAxis.setFrom(value);
  final NotifyingVector3 _upAxis = NotifyingVector3.copy(
    upAxis ?? Vector3(0, 1, 0),
  );

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

  // The bundle of the vertex stage for surfaces in [vertexLayout], and of
  // the fragment stage with 16 slots of foam sources.
  static const String _maskedBundle =
      'packages/flame_3d/assets/shaders/water_material_masked.shaderbundle';

  // The variant for surfaces in [vertexLayout].
  final Shader _maskedVertexShader = VertexShader.fromAsset(
    _maskedBundle,
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
  static final Vector4 _causticColorValue = Vector4.zero();
  static final List<Vector4> _ripplePositions = List.generate(
    WaterRipples.capacity,
    (_) => Vector4.zero(),
  );
  static final List<Vector4> _rippleShapes = List.generate(
    WaterRipples.capacity,
    (_) => Vector4.zero(),
  );
  static final List<Vector4> _foamSourcePositions = List.generate(
    WaterFoamSources.maxCapacity,
    (_) => Vector4.zero(),
  );
  static final List<Vector4> _foamSourceShapes = List.generate(
    WaterFoamSources.maxCapacity,
    (_) => Vector4.zero(),
  );
  static final List<Vector4> _foamSourceBounds = List.generate(
    WaterFoamSources.maxCapacity,
    (_) => Vector4.zero(),
  );
  static final Vector2 _foamSourceOrigin = Vector2.zero();

  @override
  void apply(RenderContext context) {
    final ripples = this.ripples;
    final foamSources = this.foamSources;
    if (ripples != null || foamSources != null) {
      _planeAxes(upAxis);
    }
    // The slots of the sources for the fragments, the circles of those
    // above 0 for the vertices.
    var foamSourceCount = 0;
    var foamBoundCount = 0;
    if (foamSources != null) {
      foamSourceCount = foamSources.writeUniforms(
        _uAxis,
        _vAxis,
        _foamSourcePositions,
        _foamSourceShapes,
      );
      foamBoundCount = foamSources.writeBounds(
        _uAxis,
        _vAxis,
        _foamSourceBounds,
        _foamSourceOrigin,
      );
    }
    _applyVertex(vertexShader, foamBoundCount);
    if (_maskedInUse) {
      _applyVertex(_maskedVertexShader, foamBoundCount);
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
        _shoreVec..setValues(
          shoreFoamDepth,
          refractionStrength,
          edgeFoamPhase(time, animationPeriod, edgeFoamMotion),
          foamLightTint.clamp(0.0, 1.0),
        ),
      )
      ..setVector4(
        'upAxis',
        _upVec..setValues(
          upAxis.x,
          upAxis.y,
          upAxis.z,
          foamLightFloor > 0 ? foamLightFloor : 0,
        ),
      );
    if (!block.hasMember('pattern')) {
      return;
    }

    var rippleCount = 0;
    if (ripples != null) {
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
    for (var i = 0; i < foamSourceCount; i++) {
      block
        ..setVector4(
          'foamSourcePositions',
          _foamSourcePositions[i],
          index: i,
        )
        ..setVector4('foamSourceShapes', _foamSourceShapes[i], index: i);
    }
    final caustics = math.max(0.0, causticStrength);
    final sparkles = math.max(0.0, sparkleStrength);
    final addsLight = caustics > 0 || sparkles > 0 || rippleCount > 0;
    block
      ..setVector4(
        'causticColor',
        _causticColorValue..setValues(
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
          // Negative when a source carries its pattern.
          _carriesPattern(foamSourceCount)
              ? -foamSourceCount.toDouble()
              : foamSourceCount.toDouble(),
          rippleCount.toDouble(),
        ),
      );
  }

  /// Writes the vertex stage's values, with the circles of the
  /// [foamSourceCount] foam sources above `0` (the vertices tell the
  /// fragments where none reaches, so that they skip them).
  void _applyVertex(Shader shader, int foamSourceCount) {
    final origin = _foamSourceOrigin;
    final block = shader.block(_vertexBlock)
      ..setVector4(
        'waveParams',
        _waveParams..setValues(time, waveAmplitude, waveFrequency, waveSpeed),
      )
      ..setVector4(
        'upAndSteepness',
        _upSteep..setValues(upAxis.x, upAxis.y, upAxis.z, steepness),
      )
      ..setVector4(
        'surface',
        foamSourceCount > 0
            ? (_surface..setValues(
                defaultDepth,
                foamSourceCount.toDouble(),
                origin.x,
                origin.y,
              ))
            : (_surface..setValues(defaultDepth, 0, 0, 0)),
      );
    for (var i = 0; i < foamSourceCount; i++) {
      block.setVector4('foamSourceBounds', _foamSourceBounds[i], index: i);
    }
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

  /// The phase of the foam of the foam mask and of the foam sources at
  /// [time]: [patternPhase] of `time * motion` (with [motion] at least `0`),
  /// so the foam moves [motion] times as fast as the other patterns and
  /// still loops without a jump (over `period / motion` seconds), `0` (still)
  /// when [motion] is `0`. With [motion] `1` it is [patternPhase] itself.
  static double edgeFoamPhase(double time, double period, double motion) {
    if (!(motion > 0)) {
      return 0;
    }
    return patternPhase(time * motion, period);
  }

  static double _inverse(double scale) => scale > 0 ? 1 / scale : 0;

  /// Whether one of the first [count] slots of foam sources written carries
  /// its pattern (a negative strength).
  static bool _carriesPattern(int count) {
    for (var i = 0; i < count; i++) {
      if (_foamSourceShapes[i].w < 0) {
        return true;
      }
    }
    return false;
  }

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
