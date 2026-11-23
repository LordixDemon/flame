import 'dart:typed_data';
import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/resources/material/material_apply_cache.dart';
import 'package:flame_3d/src/resources/material/surface_buffer_helpers.dart';
import 'package:flame_3d/src/resources/material/versioned_list.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

part 'stylized_enums.dart';
part 'stylized_surface_builder.dart';
part 'stylized_uniforms.dart';

/// {@template stylized_material}
/// A material for stylized, vertex-colored art: low-poly meshes whose
/// vertices carry a color, a baked ambient occlusion and a few masks that
/// pick per-vertex effects, optionally with a base color texture (see "Base
/// color texture").
///
/// ## Vertex data
///
/// It reads its own [vertexLayout] (build surfaces in it with [buildSurface]):
///
/// | Attribute         | Floats | Meaning                                    |
/// | ----------------- | ------ | ------------------------------------------ |
/// | `vertexPosition`  | 3      | position                                   |
/// | `vertexNormal`    | 3      | normal                                     |
/// | `vertexColor`     | 4      | color (rgb) and alpha                      |
/// | `vertexMasks`     | 4      | tint, accent, emissive masks and gloss     |
/// | `vertexOcclusion` | 1      | ambient occlusion, 1 unoccluded            |
/// | `vertexWind`      | 3      | sway weight, phase (turns), flutter weight |
///
/// That is 18 floats per vertex. The masks blend from `0` (none) to `1`
/// (fully). Gloss is the specular strength of the vertex and may exceed `1`
/// for extra bright highlights. The wind of a vertex is how much it sways,
/// the phase of its sway and flutter in turns (`0` to `1` is a full turn) and
/// how much it flutters, see "Wind".
///
/// It also draws surfaces in the standard layout ([VertexLayout.standard],
/// including the built-in meshes and skinned models): their vertex color is
/// used, they are unoccluded, tinted by the instance color everywhere, and
/// have no accent, emission, gloss nor wind.
///
/// ## Base color texture
///
/// With a [baseColorTexture], the surface color is the vertex color times
/// the texture ([BaseColorTextureMode.multiply], the default) or the texture
/// alone ([BaseColorTextureMode.replace]), alpha included, sampled at the
/// texture coordinates of the vertex (`vertexTexCoord`); everything else
/// (lighting, masks, palettes, wind, water volume, fog) is as without one.
/// The texture is used as it is stored, like the vertex colors (no sRGB
/// decoding), as straight alpha: textures made from Flutter images are
/// premultiplied, which darkens their semi-transparent texels. Textured
/// surfaces need texture coordinates: build them in [texturedVertexLayout] or
/// [texturedSkinnedVertexLayout] ([buildSurface] with `texCoords`), or in the
/// standard layout, whose texture coordinates are used. Drawing a surface
/// without them throws a [StateError].
///
/// A textured material draws with stages of its own, which a material without
/// a texture never loads: one more texture and two more floats per vertex, the
/// same uniform vectors, and its draws batch like the others (the texture is
/// the material's: instances of one surface with one material are one draw).
/// [alphaCutoff] discards the pixels whose alpha is below it and makes the
/// others opaque, as glTF's `MASK` alpha mode does.
///
/// ## Skinning
///
/// Surfaces in [skinnedVertexLayout], [vertexLayout] followed by
/// `vertexJoints` and `vertexWeights` (4 floats each: up to four joint
/// indices per vertex and their weights, 26 floats per vertex in all), are
/// skinned: each vertex is moved by the weighted sum of the joint matrices of
/// its draw, then drawn as above, its wind added in model space after the
/// skinning. Build them
/// with [buildSurface] and its `joints` and `weights`, and give the joint
/// matrices with every draw (`RenderContext3D.drawSurface(jointTransforms:)`,
/// or `MeshComponent.jointTransforms`); at most [maxJoints] (64) joints per
/// draw. A vertex
/// whose weights are all `0` keeps its position. Skinned draws are never
/// batched: each is one draw call.
///
/// ## Per-instance data
///
/// Besides the per-instance color, which tints the vertices of the tint mask,
/// each object can vary through its per-instance data
/// (`MeshComponent.instanceData`, zero by default):
///
/// - `x`, the emissive boost: added to [emissiveStrength] on the vertices of
///   the emissive mask; from `0` to `1` it also moves their glow color (see
///   "Glow colors") towards [emissiveBoostColor];
/// - `y`, the highlight: [highlightColor] times it is added to every vertex;
/// - `z`, the wind strength, added to `1`: `-1` stills the sway of the object
///   and `1` doubles it;
/// - `w`, the fade: the opacity of the object is `1 - w`, which shows when
///   the material is translucent (see below).
///
/// Objects that differ only in their color and instance data are still drawn
/// with one instanced draw call per surface.
///
/// ## Shading
///
/// With `n` the normal, `v` the direction to the viewer, `up` the hemisphere
/// light's up axis, `hemi = 0.5 + 0.5 * n·up`, `bounce = max(0, -n·up)` and
/// `boost`, `highlight` and `fade` from the instance data:
///
/// ```text
/// base = albedoColor * vertexColor * mix(1, instance color, tint mask)
///        * mix(1, accentColor, accent mask)
/// lit  = occlusion * (ambient light
///          + hemisphere intensity * (ambientBase
///                                    + skyFill * skyFillWeight * sky * hemi
///                                    + groundBounce * ground * bounce))
///        + Σ directional: max(0, n·l) * intensity * color
///        + Σ point: intensity * color * falloff * max(pointLightWrap, n·l)
/// spec = (only where gloss > specularThreshold)
///        Σ directional: (n·h)^specularPower * light.specular
///          * gloss * specularStrength
/// rim  = (1 - n·v)^rimPower * rimStrength * (sky + rimColor)
/// cap  = where gloss > gemThreshold:
///          gemMatCapTexture(view-space normal) * gemMatCapStrength
///        elsewhere, where gloss > matCapThreshold:
///          matCapTexture(view-space normal) * matCapStrength
///          * mix(1, gloss, matCapGlossWeight)
/// surface = base * lit + rim
/// shaded  = mix(surface + cap, min(surface, 1) * reflected, matCapMetallic)
///           + spec + highlight * highlightColor
/// glow = clamp(emissive mask * (emissiveStrength + boost), 0, 1)
/// out  = mix(shaded,
///            mix(glow color, emissiveBoostColor ?? glow color,
///                clamp(boost, 0, 1)),
///            glow)
/// alpha = albedoColor.a * vertex alpha * (1 - fade)
/// ```
///
/// Last comes the color grade of the material, which leaves the color as it
/// is by default: the color, clamped to `[0, 1]`, is desaturated towards its
/// luminosity `0.3 r + 0.59 g + 0.11 b` as [saturation] goes from `1` to
/// `0`, then covered by [overlayColor] as far as its alpha goes. One material
/// per grade greys out or tints whole objects (a disabled or stunned look,
/// a shield's glint) whatever their vertex colors.
///
/// `falloff` is the point light's: `(1 - d / range)²` with a range, `1 / d²`
/// without. MatCap textures are sampled at `(0.5 + 0.5 x, 0.5 - 0.5 y)` of
/// the view-space normal, `x` pointing right and `y` up in the picture, also
/// when the projection mirrors it. `reflected` is `cap` on the vertices that
/// get a MatCap texture and `1` on the others. Highlights are white and
/// follow the direction of the directional lights, not their intensity. The
/// result is clamped to `[0, 1]`, with no tone mapping, graded, and output
/// premultiplied by its alpha.
///
/// ## Glow colors
///
/// The vertices of the emissive mask glow in [emissiveColor] by default. With
/// [emissiveColorSource] they glow in a color of their instance instead, so
/// that instances of one mesh glow in different colors in one draw:
///
/// - [EmissiveColorSource.instanceColor]: the color of the instance, the one
///   that tints the vertices of the tint mask (a tinted inlay glows in its
///   tint);
/// - [EmissiveColorSource.accent]: its accent, the [accentPalette] entry it
///   picks with [packPaletteAndFade], or [accentColor] without one;
/// - [EmissiveColorSource.rim]: the color of its [rimPalette] entry, or
///   [emissiveColor] without one. The alpha of the entry, the strength of its
///   rim, is not used: an entry of alpha `0` glows without a rim.
///
/// Only the color changes: the glow still mixes the shaded color towards it
/// by `glow` (above), and the boost still moves it towards
/// [emissiveBoostColor] when that is set. An instance looks exactly like the
/// same instance drawn with a material whose [emissiveColor] is its glow
/// color, on every pixel, in the stylized layout (skinned or not) and every
/// render state. Surfaces in the standard layout have no emissive mask, so
/// they do not glow, whatever the source.
///
/// ## Metals
///
/// By default a MatCap texture is a sheen added over the surface: a clear
/// coat, the glint of a gem. With [matCapMetallic] at `1` it is the
/// surface's own reflection instead, tinted by it: the lit surface, at most
/// `1` per channel, multiplies the texture, so that a gold MatCap on a gold
/// tint gives a deep, saturated gold where an added sheen would wash it out
/// towards white. A fully lit white vertex then shows the texture as painted;
/// vertices without a MatCap keep their lit color.
///
/// ## Wind
///
/// A vertex moves along [windDirection] by
///
/// ```text
/// offset  = (sway + flutter) * gust * (1 + instanceData.z)
/// sway    = windAmplitude * sin(windTime * windFrequency
///             + dot(origin, windPhase) + phase) * sway weight
/// flutter = windFlutterAmplitude * sin(windTime * windFlutterFrequency
///             + dot(origin, windPhase) + phase) * flutter weight
/// gust    = 1 + windGustAmplitude * sin(windTime * windGustFrequency
///             - dot(origin, windGustDirection) * windGustPhaseScale)
/// ```
///
/// where `origin` is the world position of its object, `phase` the phase of
/// the vertex in radians (its phase in turns times `2π`) and
/// `instanceData.z` the wind strength of its instance. The flutter is a
/// fast, small sway of the vertices with a flutter weight (leaves, flags);
/// the gust a slow wave that crosses the scene along [windGustDirection]
/// (normalized), strengthening and weakening the wind of the objects it
/// reaches. Both are off by default (their amplitudes are `0`), and so is the
/// phase of vertices built without one.
///
/// [windSpace] is the space of the direction and of the amplitudes:
///
/// - [WindSpace.world] (the default): world space, every object sways the
///   same way by the same distance;
/// - [WindSpace.model]: the model space of each object, so that the sway
///   turns and scales with the object, as if it were part of its mesh;
/// - [WindSpace.worldScaled]: the direction in world space, the amplitudes
///   scaled by the scale of each object along its up axis ([windUpAxis], in
///   model space): objects of every orientation and size sway the same world
///   way, each in proportion to its height.
///
/// The wind does not move the shadows: shadows are cast from the rest
/// positions.
///
/// The defaults give a soft, toy-like look under a [HemisphereLight] and a
/// [DirectionalLight].
///
/// It is drawn instanced and batches like any opaque material: vary objects
/// with the per-instance color and data, or with distinct materials (one per
/// accent color, for instance).
///
/// ## Translucency
///
/// With `translucent: true` the material blends its premultiplied output over
/// what is behind it, without writing depth, and its draws are sorted back to
/// front after the opaque ones, like every translucent draw: objects can then
/// fade out with the `w` of their instance data, a see-through preview for
/// instance. Translucent draws of one surface that are consecutive in that
/// order are still batched.
///
/// ## Shadows
///
/// It receives the shadows of the directional light that casts them (see
/// [ShadowSettings]): where a surface is in shadow, that light's direct light
/// (and its highlights) is multiplied by `mix(white, color, strength)` of the
/// settings, so that colored shadows tint the surface rather than darken it;
/// ambient, hemisphere and the other lights stay. Opaque stylized materials
/// cast shadows and translucent ones do not (see [Material.castsShadows]);
/// the wind (sway, flutter and gusts) does not move the shadows.
///
/// ## Water
///
/// Below the level of the world's water volume (`World3D.waterVolume`, see
/// [WaterVolumeSettings]), the color of a surface is tinted and darkened
/// with its depth and lit by caustics, and surfaces foam where they cross
/// the level, before the fog; without a volume nothing changes.
///
/// Not available on the web yet: creating one there throws an
/// [UnsupportedError].
/// {@endtemplate}
class StylizedMaterial({
  var Color _albedoColor = const Color(0xFFFFFFFF),
  var Color _accentColor = const Color(0xFFFFFFFF),

  /// Optional palette of up to [maxAccentPaletteSize] (`16`) accent colors that
  /// individual instances can select through [packAccentAndFade] in
  /// `instanceData.w` without breaking instanced batching.
  List<Color> accentPalette = const [],

  var Color _emissiveColor = const Color(0xFFFFFFFF),
  var EmissiveColorSource _emissiveColorSource =
      EmissiveColorSource.emissiveColor,
  var double _emissiveStrength = 1.0,
  var Color? _emissiveBoostColor,
  var Color _highlightColor = const Color(0xFFFFFFFF),
  var Color _ambientBase = const Color.from(
    alpha: 1,
    red: 0.65,
    green: 0.65,
    blue: 0.65,
  ),
  var double _skyFill = 0.35,

  /// The weight of each channel (red, green, blue) of the sky fill, `(1, 1,
  /// 1)` by default: a surface facing up gets `skyFill * skyFillWeight`
  /// times the hemisphere light's sky color.
  Vector3? skyFillWeight,

  var double _groundBounce = 0.1,
  var double _pointLightWrap = 0.18,
  var double _specularStrength = 0.28,
  var double _specularPower = 8,
  var double _specularThreshold = 0.12,
  var double _rimStrength = 0.14,
  var double _rimPower = 3,
  var Color _rimColor = const Color(0xFF000000),

  /// Optional palette of up to [maxRimPaletteSize] (`8`) rim highlight
  /// colors that individual instances select with [packPaletteAndFade]
  /// (`rim:`) in `instanceData.w`, without breaking instanced batching: the
  /// selected color is added on the edges facing away from the viewer, as
  /// `pow(1 - n·v, rimPalettePower) * color.rgb * color.a *
  /// rimPaletteStrength`, on every vertex (no mask) and on top of the
  /// material's own rim light. See "Rim highlight palette".
  List<Color> rimPalette = const [],

  var double _rimPalettePower = 2,
  var double _rimPaletteStrength = 1,
  var Texture? _matCapTexture,
  var double _matCapStrength = 1.0,
  var double _matCapThreshold = 0,
  var double _matCapGlossWeight = 1,
  var Texture? _gemMatCapTexture,
  var double _gemMatCapStrength = 1.0,
  var double _gemThreshold = 1.0,
  var double _matCapMetallic = 0,
  var double _saturation = 1,
  var Color _overlayColor = const Color(0x00000000),

  /// The direction vertices sway in, in [windSpace].
  Vector3? windDirection,

  var double _windAmplitude = 0.032,
  var WindSpace _windSpace = WindSpace.world,

  /// The up axis of the objects, in their model space, along which
  /// [WindSpace.worldScaled] measures their scale: `(0, 1, 0)` by default.
  /// It is normalized.
  Vector3? windUpAxis,

  var double _windFrequency = 2.3,

  /// How the phase of the sway (and of the flutter) changes with the world
  /// position of objects, in radians per unit along each axis, so that they
  /// do not sway in unison.
  Vector3? windPhase,

  var double _windFlutterAmplitude = 0,
  var double _windFlutterFrequency = 12,
  var double _windGustAmplitude = 0,
  var double _windGustFrequency = 0.8,

  /// The direction the gusts travel in, in world space: `(1, 0, 0)` by
  /// default. It is normalized.
  Vector3? windGustDirection,

  var double _windGustPhaseScale = 0.5,
  var double _windTime = 0,

  /// Whether the material is drawn translucent: blended with premultiplied
  /// alpha, without depth writes, sorted back to front (see [renderState]).
  bool translucent = false,

  /// When `translucent` is `true`, whether to automatically record an internal
  /// depth prepass ([RenderState.singlePiecePremultipliedAlphaBlend]) so
  /// overlapping multi-part meshes and skinned models fade as one seamless
  /// piece.
  bool singlePieceTranslucent = false,

  var bool _ditherFade = false,
  var double _depthBias = 0,
  var Texture? _baseColorTexture,
  var BaseColorTextureMode _baseColorTextureMode =
      BaseColorTextureMode.multiply,
  var double _alphaCutoff = 0,
}) extends Material {
  /// {@macro stylized_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          _bundle,
          slots: [RenderContext3D.cameraMatricesBlock, 'Wind'],
        ),
        fragmentShader: FragmentShader.fromAsset(
          _bundle,
          slots: [
            'matCapTexture',
            'gemMatCapTexture',
            'Material',
            // The camera, the lights and the shadows of the pass.
            RenderContext3D.stylizedPassBlock,
            RenderContext3D.shadowMapSampler,
            RenderContext3D.lightGridSampler,
          ],
        ),
      ) {
    if (kIsWeb) {
      throw UnsupportedError(
        'StylizedMaterial is not available on the web yet: it has no WebGPU '
        'shaders.',
      );
    }
    _plainFragment = super.fragmentShader;
    if (baseColorTexture != null) {
      _texturedFragment.checkDeviceSupport(owner: runtimeType);
    }
    if (translucent) {
      setInitialState(
        renderState: singlePieceTranslucent
            ? RenderState.singlePiecePremultipliedAlphaBlend
            : translucentRenderState,
      );
    }
    _accentPalette.onChanged = markChanged;
    _rimPalette.onChanged = markChanged;
    _skyFillWeight.addListener(markChanged);
    _windDirection.addListener(markChanged);
    _windPhase.addListener(markChanged);
    _windUpAxis.addListener(markChanged);
    _windGustDirection.addListener(markChanged);
  }

  /// Multiplies the vertex color.
  Color get albedoColor => _albedoColor;
  set albedoColor(Color value) =>
      _albedoColor = noteChange(_albedoColor, value);

  /// Multiplies the color of the vertices of the accent mask.
  Color get accentColor => _accentColor;
  set accentColor(Color value) =>
      _accentColor = noteChange(_accentColor, value);

  /// The color the vertices of the emissive mask glow with, unless
  /// [emissiveColorSource] takes it from each instance.
  Color get emissiveColor => _emissiveColor;
  set emissiveColor(Color value) =>
      _emissiveColor = noteChange(_emissiveColor, value);

  /// Where the vertices of the emissive mask take the color they glow with:
  /// the material's [emissiveColor] ([EmissiveColorSource.emissiveColor], the
  /// default), or a color of each instance, so that the instances of one mesh
  /// glow in colors of their own and still share one draw: its color
  /// ([EmissiveColorSource.instanceColor]), its accent
  /// ([EmissiveColorSource.accent]) or its [rimPalette] entry
  /// ([EmissiveColorSource.rim]). See "Glow colors".
  EmissiveColorSource get emissiveColorSource => _emissiveColorSource;
  set emissiveColorSource(EmissiveColorSource value) =>
      _emissiveColorSource = noteChange(_emissiveColorSource, value);

  /// How strongly the vertices of the emissive mask glow, from `0` (lit like
  /// the others) to `1` (their glow color alone).
  double get emissiveStrength => _emissiveStrength;
  set emissiveStrength(double value) =>
      _emissiveStrength = noteChange(_emissiveStrength, value);

  /// The color the vertices of the emissive mask glow with in objects whose
  /// emissive boost (the `x` of their instance data) is `1`; the color moves
  /// from their glow color ([emissiveColor], or the instance's color picked
  /// by [emissiveColorSource]) towards it as the boost goes from `0` to `1`.
  /// `null` (the default) keeps the glow color of each object.
  Color? get emissiveBoostColor => _emissiveBoostColor;
  set emissiveBoostColor(Color? value) =>
      _emissiveBoostColor = noteChange(_emissiveBoostColor, value);

  /// The color added to objects in proportion to their highlight (the `y` of
  /// their instance data).
  Color get highlightColor => _highlightColor;
  set highlightColor(Color value) =>
      _highlightColor = noteChange(_highlightColor, value);

  /// The ambient light a hemisphere light gives every surface, whatever its
  /// orientation, per unit of the hemisphere light's intensity.
  Color get ambientBase => _ambientBase;
  set ambientBase(Color value) =>
      _ambientBase = noteChange(_ambientBase, value);

  /// How much of the hemisphere light's sky color surfaces facing up get,
  /// times [skyFillWeight].
  double get skyFill => _skyFill;
  set skyFill(double value) => _skyFill = noteChange(_skyFill, value);

  /// How much of the hemisphere light's ground color surfaces facing down
  /// get.
  double get groundBounce => _groundBounce;
  set groundBounce(double value) =>
      _groundBounce = noteChange(_groundBounce, value);

  /// The least a point light lights a surface, even facing away from it, as
  /// a fraction of its light.
  double get pointLightWrap => _pointLightWrap;
  set pointLightWrap(double value) =>
      _pointLightWrap = noteChange(_pointLightWrap, value);

  /// The strength of the highlights of a vertex of gloss `1`.
  double get specularStrength => _specularStrength;
  set specularStrength(double value) =>
      _specularStrength = noteChange(_specularStrength, value);

  /// The exponent of the highlights: higher is tighter.
  double get specularPower => _specularPower;
  set specularPower(double value) =>
      _specularPower = noteChange(_specularPower, value);

  /// Vertices with no more gloss than this have no highlights.
  double get specularThreshold => _specularThreshold;
  set specularThreshold(double value) =>
      _specularThreshold = noteChange(_specularThreshold, value);

  /// The strength of the rim light, on the edges facing away from the
  /// viewer.
  double get rimStrength => _rimStrength;
  set rimStrength(double value) =>
      _rimStrength = noteChange(_rimStrength, value);

  /// The exponent of the rim light: higher is thinner.
  double get rimPower => _rimPower;
  set rimPower(double value) => _rimPower = noteChange(_rimPower, value);

  /// Added to the hemisphere light's sky color for the rim light.
  Color get rimColor => _rimColor;
  set rimColor(Color value) => _rimColor = noteChange(_rimColor, value);

  /// The exponent of the [rimPalette] rims: higher is thinner.
  double get rimPalettePower => _rimPalettePower;
  set rimPalettePower(double value) =>
      _rimPalettePower = noteChange(_rimPalettePower, value);

  /// Multiplies the [rimPalette] rims (whose colors' alpha is their own
  /// strength), so that they can be brighter than `1`.
  double get rimPaletteStrength => _rimPaletteStrength;
  set rimPaletteStrength(double value) =>
      _rimPaletteStrength = noteChange(_rimPaletteStrength, value);

  /// An optional MatCap texture, a sheen added where vertices have more gloss
  /// than [matCapThreshold] (and no more than [gemThreshold] when there is a
  /// [gemMatCapTexture]).
  Texture? get matCapTexture => _matCapTexture;
  set matCapTexture(Texture? value) =>
      _matCapTexture = noteChange(_matCapTexture, value);

  /// The strength of the [matCapTexture] (for a vertex of gloss `1` when
  /// [matCapGlossWeight] is `1`).
  double get matCapStrength => _matCapStrength;
  set matCapStrength(double value) =>
      _matCapStrength = noteChange(_matCapStrength, value);

  /// Vertices with no more gloss than this get no [matCapTexture].
  double get matCapThreshold => _matCapThreshold;
  set matCapThreshold(double value) =>
      _matCapThreshold = noteChange(_matCapThreshold, value);

  /// How much the gloss of a vertex scales its [matCapTexture]: `1` (the
  /// default) in proportion to the gloss, `0` at [matCapStrength] whatever
  /// the gloss.
  double get matCapGlossWeight => _matCapGlossWeight;
  set matCapGlossWeight(double value) =>
      _matCapGlossWeight = noteChange(_matCapGlossWeight, value);

  /// An optional second MatCap texture, for the glossiest vertices (gems, for
  /// instance): those with more gloss than [gemThreshold] get it at
  /// [gemMatCapStrength] instead of the [matCapTexture].
  Texture? get gemMatCapTexture => _gemMatCapTexture;
  set gemMatCapTexture(Texture? value) =>
      _gemMatCapTexture = noteChange(_gemMatCapTexture, value);

  /// The strength of the [gemMatCapTexture].
  double get gemMatCapStrength => _gemMatCapStrength;
  set gemMatCapStrength(double value) =>
      _gemMatCapStrength = noteChange(_gemMatCapStrength, value);

  /// Vertices with more gloss than this get the [gemMatCapTexture], when
  /// there is one.
  double get gemThreshold => _gemThreshold;
  set gemThreshold(double value) =>
      _gemThreshold = noteChange(_gemThreshold, value);

  /// How the MatCap textures combine with the lit surface: `0` (the
  /// default) adds them, as a sheen; `1` multiplies the lit surface (at most
  /// `1`) by them, as the reflection of a metal; values in between blend the
  /// two. See the "Metals" section of [StylizedMaterial].
  double get matCapMetallic => _matCapMetallic;
  set matCapMetallic(double value) =>
      _matCapMetallic = noteChange(_matCapMetallic, value);

  /// How saturated the final color stays: `1` (the default) leaves it as it
  /// is, `0` turns it into its luminosity, a grey (see "Shading").
  double get saturation => _saturation;
  set saturation(double value) => _saturation = noteChange(_saturation, value);

  /// A color laid over the final color as far as its alpha goes: transparent
  /// (the default) leaves the color as it is (see "Shading").
  Color get overlayColor => _overlayColor;
  set overlayColor(Color value) =>
      _overlayColor = noteChange(_overlayColor, value);

  /// How far vertices of sway weight `1` sway, in [windSpace] units.
  double get windAmplitude => _windAmplitude;
  set windAmplitude(double value) =>
      _windAmplitude = noteChange(_windAmplitude, value);

  /// The space of [windDirection] and of the amplitudes of the wind: the
  /// world (the default), the model space of each object, or the world
  /// scaled by the size of each object (see [WindSpace]).
  WindSpace get windSpace => _windSpace;
  set windSpace(WindSpace value) => _windSpace = noteChange(_windSpace, value);

  /// The angular frequency of the sway, in radians per unit of [windTime].
  double get windFrequency => _windFrequency;
  set windFrequency(double value) =>
      _windFrequency = noteChange(_windFrequency, value);

  /// How far vertices of flutter weight `1` flutter, in [windSpace] units:
  /// `0` (the default) turns the flutter off.
  double get windFlutterAmplitude => _windFlutterAmplitude;
  set windFlutterAmplitude(double value) =>
      _windFlutterAmplitude = noteChange(_windFlutterAmplitude, value);

  /// The angular frequency of the flutter, in radians per unit of
  /// [windTime]: a fast sway, faster than [windFrequency].
  double get windFlutterFrequency => _windFlutterFrequency;
  set windFlutterFrequency(double value) =>
      _windFlutterFrequency = noteChange(_windFlutterFrequency, value);

  /// How much gusts strengthen and weaken the wind, as a fraction of it:
  /// the wind of an object goes from `1 - windGustAmplitude` to
  /// `1 + windGustAmplitude` times its strength as gusts cross it. `0` (the
  /// default) turns the gusts off.
  double get windGustAmplitude => _windGustAmplitude;
  set windGustAmplitude(double value) =>
      _windGustAmplitude = noteChange(_windGustAmplitude, value);

  /// The angular frequency of the gusts, in radians per unit of [windTime]:
  /// a slow wave, slower than [windFrequency].
  double get windGustFrequency => _windGustFrequency;
  set windGustFrequency(double value) =>
      _windGustFrequency = noteChange(_windGustFrequency, value);

  /// How fast the phase of the gusts changes along [windGustDirection], in
  /// radians per world unit: gusts travel at
  /// `windGustFrequency / windGustPhaseScale` world units per unit of
  /// [windTime], and `0` gusts the whole scene in unison.
  double get windGustPhaseScale => _windGustPhaseScale;
  set windGustPhaseScale(double value) =>
      _windGustPhaseScale = noteChange(_windGustPhaseScale, value);

  /// The time of the wind, to advance every frame (in seconds).
  double get windTime => _windTime;
  set windTime(double value) => _windTime = noteTime(_windTime, value);

  /// Whether opaque draws dissolve via a `4x4` screen-space Bayer dither
  /// pattern driven by `albedoColor.a * instanceColor.a * (1 - fade)`, writing
  /// full depth on kept fragments with zero translucent overdraw.
  bool get ditherFade => _ditherFade;
  set ditherFade(bool value) => _ditherFade = noteChange(_ditherFade, value);

  /// A clip-space depth bias: every vertex's depth (in the `0..1` depth
  /// range of the picture) is lowered by it, so the objects of this material
  /// are drawn in front of surfaces up to that much depth nearer the camera,
  /// without moving on screen. Negative values push them behind. The shadow
  /// pass and the depth-normal prepass ignore it: the object casts its shadow
  /// from where it is. See "Depth bias".
  double get depthBias => _depthBias;
  set depthBias(double value) => _depthBias = noteChange(_depthBias, value);

  /// An optional base color texture, which multiplies or replaces the vertex
  /// color as [baseColorTextureMode] says, sampled at the texture coordinates
  /// of each vertex: `null` (the default) draws without one, at the cost of
  /// before. See "Base color texture".
  Texture? get baseColorTexture => _baseColorTexture;
  set baseColorTexture(Texture? value) =>
      _baseColorTexture = noteChange(_baseColorTexture, value);

  /// How the [baseColorTexture] combines with the vertex color: it multiplies
  /// it (the default) or replaces it.
  BaseColorTextureMode get baseColorTextureMode => _baseColorTextureMode;
  set baseColorTextureMode(BaseColorTextureMode value) =>
      _baseColorTextureMode = noteChange(_baseColorTextureMode, value);

  /// With a [baseColorTexture], the pixels whose alpha (`albedoColor.a` times
  /// the alpha of the surface color) is below it are discarded and the others
  /// are opaque (the instance alpha and the fade still apply), as glTF's
  /// `MASK` alpha mode draws them. `0` (the default) keeps every pixel as it
  /// is. Shadows are cast by whole triangles.
  double get alphaCutoff => _alphaCutoff;
  set alphaCutoff(double value) =>
      _alphaCutoff = noteChange(_alphaCutoff, value);

  /// The render state of translucent stylized materials: blended with
  /// premultiplied alpha, depth tested, without depth writes.
  static const RenderState translucentRenderState =
      RenderState.premultipliedAlphaBlend;

  /// Maximum number of entries supported in [accentPalette].
  static const int maxAccentPaletteSize = 16;

  /// Optional per-instance accent palette (up to [maxAccentPaletteSize]
  /// colors). Its changes count as changes of the material ([version]).
  List<Color> get accentPalette => _accentPalette;
  final VersionedList<Color> _accentPalette = VersionedList(accentPalette);

  /// Maximum number of entries supported in [rimPalette].
  static const int maxRimPaletteSize = 8;

  /// Optional per-instance rim highlight palette (up to [maxRimPaletteSize]
  /// colors), see [packPaletteAndFade]. Its changes count as changes of the
  /// material ([version]).
  List<Color> get rimPalette => _rimPalette;
  final VersionedList<Color> _rimPalette = VersionedList(rimPalette);

  /// Encodes an [accentIndex] (`0` to `maxAccentPaletteSize - 1`) into
  /// [accentPalette] together with a [fade] in `[0, 1]` as a single float for
  /// `instanceData.w`: `packPaletteAndFade(accent: accentIndex, fade: fade)`.
  ///
  /// Plain `instanceData.w` values below `2.0` keep their ordinary `[0, 1]`
  /// fade meaning and use [accentColor].
  static double packAccentAndFade(int accentIndex, {double fade = 0.0}) {
    RangeError.checkValueInInterval(
      accentIndex,
      0,
      maxAccentPaletteSize - 1,
      'accentIndex',
    );
    return packPaletteAndFade(accent: accentIndex, fade: fade);
  }

  /// Encodes an index into [accentPalette] ([accent], `0` to
  /// `maxAccentPaletteSize - 1`), an index into [rimPalette] ([rim], `0` to
  /// `maxRimPaletteSize - 1`) and a [fade] in `[0, 1]` as a single float for
  /// `instanceData.w`.
  ///
  /// The value is `(a + 17 * r) * 4 + fade`, with `a` and `r` the indices
  /// plus one, or `0` for none: without a [rim] it is [packAccentAndFade]'s,
  /// and without either it is the plain fade. An object without an [accent]
  /// keeps [accentColor]; one without a [rim] gets no palette rim.
  ///
  /// The vertex shader decodes the value, exactly, so an object drawn with
  /// palette entries looks exactly like the same object drawn with a
  /// material of those colors and the packed fade, on every pixel. Packing
  /// rounds the [fade] to a multiple of `1 / 16384` at most (finer for low
  /// indices): `0`, `0.25` or `1` are kept as they are.
  static double packPaletteAndFade({int? accent, int? rim, double fade = 0}) {
    if (accent != null) {
      RangeError.checkValueInInterval(
        accent,
        0,
        maxAccentPaletteSize - 1,
        'accent',
      );
    }
    if (rim != null) {
      RangeError.checkValueInInterval(rim, 0, maxRimPaletteSize - 1, 'rim');
    }
    final f = fade.clamp(0.0, 1.0);
    if (accent == null && rim == null) {
      return f;
    }
    final slot =
        (accent == null ? 0 : accent + 1) + 17 * (rim == null ? 0 : rim + 1);
    return slot * 4.0 + f;
  }

  // Assigning one of the vectors below copies it; changing one in place
  // counts as a change of the material.

  /// The weight of each channel of the sky fill, see [skyFill].
  Vector3 get skyFillWeight => _skyFillWeight;
  set skyFillWeight(Vector3 value) => _skyFillWeight.setFrom(value);
  final NotifyingVector3 _skyFillWeight = NotifyingVector3.copy(
    skyFillWeight ?? Vector3.all(1),
  );

  /// The direction vertices sway in, in [windSpace].
  Vector3 get windDirection => _windDirection;
  set windDirection(Vector3 value) => _windDirection.setFrom(value);
  final NotifyingVector3 _windDirection = NotifyingVector3.copy(
    windDirection ?? Vector3(1, 0, 0),
  );

  /// How the phase of the sway changes with the world position of objects.
  Vector3 get windPhase => _windPhase;
  set windPhase(Vector3 value) => _windPhase.setFrom(value);
  final NotifyingVector3 _windPhase = NotifyingVector3.copy(
    windPhase ?? Vector3(0.7, 0, 0.5),
  );

  /// The up axis of the objects, in their model space, see [windSpace].
  Vector3 get windUpAxis => _windUpAxis;
  set windUpAxis(Vector3 value) => _windUpAxis.setFrom(value);
  final NotifyingVector3 _windUpAxis = NotifyingVector3.copy(
    windUpAxis ?? Vector3(0, 1, 0),
  );

  /// The direction the gusts travel in, in world space.
  Vector3 get windGustDirection => _windGustDirection;
  set windGustDirection(Vector3 value) => _windGustDirection.setFrom(value);
  final NotifyingVector3 _windGustDirection = NotifyingVector3.copy(
    windGustDirection ?? Vector3(1, 0, 0),
  );

  static const _bundle =
      'packages/flame_3d/assets/shaders/stylized_material.shaderbundle';

  // The block of the standard layout's vertex stage holding [depthBias]
  // (the stylized layout keeps it in its Wind block).
  static const _depthBlock = 'StylizedDepth';

  /// The layout of the vertices [StylizedMaterial] reads, 18 floats per
  /// vertex: see [StylizedMaterial].
  static final VertexLayout vertexLayout = VertexLayout(const [
    VertexAttribute(VertexLayout.positionAttribute, 3),
    VertexAttribute('vertexNormal', 3),
    VertexAttribute('vertexColor', 4),
    VertexAttribute(masksAttribute, 4),
    VertexAttribute('vertexOcclusion', 1),
    VertexAttribute(windAttribute, 3),
  ]);

  /// The name of the masks attribute: surfaces whose layout has it are drawn
  /// as laid out in [vertexLayout], the others as in the standard layout.
  static const String masksAttribute = 'vertexMasks';

  /// The name of the wind attribute of [vertexLayout], 3 floats per vertex:
  /// the sway weight, the phase in turns and the flutter weight.
  static const String windAttribute = 'vertexWind';

  /// The name of the joint indices attribute of [skinnedVertexLayout].
  static const String jointsAttribute = 'vertexJoints';

  /// The name of the texture coordinates attribute of [texturedVertexLayout]
  /// and [texturedSkinnedVertexLayout], the one of the standard layout, 2
  /// floats per vertex: where the [baseColorTexture] is sampled.
  static const String texCoordAttribute = 'vertexTexCoord';

  /// The name of the joint weights attribute of [skinnedVertexLayout].
  static const String weightsAttribute = 'vertexWeights';

  /// The layout of skinned vertices, 26 floats per vertex: [vertexLayout]
  /// followed by four joint indices (`vertexJoints`) and their four weights
  /// (`vertexWeights`). See the "Skinning" section of [StylizedMaterial].
  static final VertexLayout skinnedVertexLayout = VertexLayout([
    ...vertexLayout.attributes,
    const VertexAttribute(jointsAttribute, 4),
    const VertexAttribute(weightsAttribute, 4),
  ]);

  /// The layout of textured vertices, 20 floats per vertex: [vertexLayout]
  /// followed by the texture coordinates of the [baseColorTexture]
  /// (`vertexTexCoord`, 2 floats). See "Base color texture".
  static final VertexLayout texturedVertexLayout = VertexLayout([
    ...vertexLayout.attributes,
    const VertexAttribute(texCoordAttribute, 2),
  ]);

  /// The layout of textured skinned vertices, 28 floats per vertex:
  /// [texturedVertexLayout] followed by four joint indices (`vertexJoints`)
  /// and their four weights (`vertexWeights`).
  static final VertexLayout texturedSkinnedVertexLayout = VertexLayout([
    ...texturedVertexLayout.attributes,
    const VertexAttribute(jointsAttribute, 4),
    const VertexAttribute(weightsAttribute, 4),
  ]);

  /// The number of joint matrices a skinned draw may have.
  static const int maxJoints = 64;

  // The variant for skinned surfaces in the stylized layout.
  final Shader _skinnedVertexShader = VertexShader.fromAsset(
    'packages/flame_3d/assets/shaders/stylized_material_skinned.shaderbundle',
    slots: [
      RenderContext3D.cameraMatricesBlock,
      'Wind',
      RenderContext3D.jointMatricesBlock,
    ],
  );

  // Whether the skinned variant drew: only then are its values written.
  bool _skinnedInUse = false;

  // The variant for surfaces without the masks (the standard layout).
  final Shader _standardVertexShader = VertexShader.fromAsset(
    'packages/flame_3d/assets/shaders/stylized_material_standard.shaderbundle',
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
      _depthBlock,
    ],
  );

  // Whether the standard variant drew: only then is its value written.
  bool _standardInUse = false;

  static const _texturedBundle =
      'packages/flame_3d/assets/shaders/stylized_material_textured.shaderbundle';

  // The fragment stage the material was created with, and the textured one,
  // made when a texture is first drawn.
  late final Shader _plainFragment;
  late final Shader _texturedFragment = FragmentShader.fromAsset(
    _texturedBundle,
    slots: [
      'matCapTexture',
      'gemMatCapTexture',
      'baseColorTexture',
      'Material',
      RenderContext3D.stylizedPassBlock,
      RenderContext3D.shadowMapSampler,
      RenderContext3D.lightGridSampler,
    ],
  );

  // The textured variants of the vertex stages, made when first drawn, and
  // whether they drew: only then are their values written.
  late final Shader _texturedVertexShader = VertexShader.fromAsset(
    _texturedBundle,
    slots: [RenderContext3D.cameraMatricesBlock, 'Wind'],
  );
  bool _texturedInUse = false;
  late final Shader _texturedSkinnedVertexShader = VertexShader.fromAsset(
    'packages/flame_3d/assets/shaders/'
    'stylized_material_textured_skinned.shaderbundle',
    slots: [
      RenderContext3D.cameraMatricesBlock,
      'Wind',
      RenderContext3D.jointMatricesBlock,
    ],
  );
  bool _texturedSkinnedInUse = false;
  late final Shader _texturedStandardVertexShader = VertexShader.fromAsset(
    'packages/flame_3d/assets/shaders/'
    'stylized_material_textured_standard.shaderbundle',
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
      _depthBlock,
    ],
  );
  bool _texturedStandardInUse = false;

  /// Whether the material draws with its textured stages: whether it has a
  /// [baseColorTexture] and its fragment shader is still its own.
  bool get _textured =>
      baseColorTexture != null &&
      identical(super.fragmentShader, _plainFragment);

  /// The fragment stage this material draws with: the textured one while it
  /// has a [baseColorTexture], unless its fragment shader was replaced by
  /// another one.
  @override
  Shader get fragmentShader =>
      _textured ? _texturedFragment : super.fragmentShader;

  VertexLayout? _lastLayout;
  bool _lastTextured = false;
  Shader? _lastShader;

  @override
  Shader vertexShaderFor(VertexLayout layout) {
    final textured = _textured;
    if (!identical(layout, _lastLayout) || textured != _lastTextured) {
      if (textured && layout.offsetOf(texCoordAttribute) == null) {
        throw StateError(
          'A StylizedMaterial with a baseColorTexture draws surfaces with '
          'texture coordinates ("$texCoordAttribute"): the standard layout, '
          'texturedVertexLayout or texturedSkinnedVertexLayout (buildSurface '
          'with texCoords). This surface is laid out as $layout',
        );
      }
      _lastLayout = layout;
      _lastTextured = textured;
      if (layout.offsetOf(masksAttribute) == null) {
        if (textured) {
          _lastShader = _texturedStandardVertexShader;
          _texturedStandardInUse = true;
        } else {
          _lastShader = _standardVertexShader;
          _standardInUse = true;
        }
      } else if (layout.offsetOf(jointsAttribute) != null &&
          layout.offsetOf(weightsAttribute) != null) {
        if (textured) {
          _lastShader = _texturedSkinnedVertexShader;
          _texturedSkinnedInUse = true;
        } else {
          _lastShader = _skinnedVertexShader;
          _skinnedInUse = true;
        }
      } else if (textured) {
        _lastShader = _texturedVertexShader;
        _texturedInUse = true;
      } else {
        _lastShader = vertexShader;
      }
    }
    return _lastShader!;
  }

  final MultiVariantApplyCache _applyCache = MultiVariantApplyCache(
    6,
    trackDeviceGeneration: true,
  );

  int _variantSlot(Shader vert) {
    if (identical(vert, super.vertexShader)) {
      return 0;
    }
    if (identical(vert, _skinnedVertexShader)) {
      return 1;
    }
    if (identical(vert, _standardVertexShader)) {
      return 2;
    }
    if (identical(vert, _texturedVertexShader)) {
      return 3;
    }
    if (identical(vert, _texturedSkinnedVertexShader)) {
      return 4;
    }
    if (identical(vert, _texturedStandardVertexShader)) {
      return 5;
    }
    return -1;
  }

  @override
  bool get hasPassStableFragmentShader => runtimeType == StylizedMaterial;

  @override
  bool get cachesApply => runtimeType == StylizedMaterial;

  @override
  void invalidateApplyCache() => _applyCache.invalidate();

  @override
  bool isApplyCacheValid(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => _applyCache.isValid(
    version: version,
    vertexShader: vertexShader,
    fragmentShader: fragmentShader,
    variantSlot: _variantSlot(vertexShader),
  );

  @override
  void recordApplyCache(
    RenderContext context,
    Shader vertexShader,
    Shader fragmentShader,
  ) => _applyCache.record(
    version: version,
    vertexShader: vertexShader,
    fragmentShader: fragmentShader,
    variantSlot: _variantSlot(vertexShader),
  );

  @override
  void visitTextures(void Function(Texture texture) visitor) {
    if (_matCapTexture case final tex?) {
      visitor(tex);
    }
    if (_gemMatCapTexture case final tex?) {
      visitor(tex);
    }
    if (_baseColorTexture case final tex?) {
      visitor(tex);
    }
  }

  @override
  void apply(RenderContext context) => _applyUniforms(context);

  Shader? _samplerCacheFrag;
  int _samplerCacheGen = -1;
  _StylizedSamplerIndices? _samplerCache;

  final Vector3 _upAxis = Vector3.zero();
  final Vector3 _gustWave = Vector3.zero();

  static final Vector3 _zero = Vector3.zero();

  /// A gloss no vertex reaches.
  static const double _never = 1e30;

  /// Builds a surface in [vertexLayout] from per-vertex arrays, drawn with
  /// [material].
  ///
  /// [positions] and [normals] hold 3 floats per vertex, [colors] 4 (RGBA,
  /// white by default) and the others one: [occlusion] (`1` by default), and
  /// [tint], [accent], [emissive], [gloss], [sway] (the sway weight),
  /// [windPhase] (the phase of the vertex's sway and flutter, in turns: `0`
  /// to `1` is a full turn) and [windFlutter] (the flutter weight), `0` by
  /// default. See the "Wind" section of [StylizedMaterial].
  /// [indices] are the triangles' vertex indices; they are stored as 16-bit
  /// integers when possible, and used as given when they are a [Uint16List]
  /// or a [Uint32List].
  ///
  /// With [joints] and [weights], 4 floats per vertex each (joint indices,
  /// below [maxJoints], and their weights), the surface is skinned and laid
  /// out in [skinnedVertexLayout] instead; both must be given together.
  ///
  /// With [texCoords], 2 floats per vertex (where the [baseColorTexture] is
  /// sampled), the surface is laid out in [texturedVertexLayout], or in
  /// [texturedSkinnedVertexLayout] when it is skinned.
  ///
  /// The bounds of the surface, which culling uses, are those of [positions]
  /// unless [aabb] is given: give bounds wide enough for every pose when the
  /// joints of a skinned surface move it outside of them.
  static Surface buildSurface({
    required List<double> positions,
    required List<double> normals,
    required List<int> indices,
    required Material material,
    List<double>? colors,
    List<double>? occlusion,
    List<double>? tint,
    List<double>? accent,
    List<double>? emissive,
    List<double>? gloss,
    List<double>? sway,
    List<double>? windPhase,
    List<double>? windFlutter,
    List<double>? joints,
    List<double>? weights,
    List<double>? texCoords,
    Aabb3? aabb,
  }) {
    return _buildStylizedSurface(
      positions: positions,
      normals: normals,
      indices: indices,
      material: material,
      colors: colors,
      occlusion: occlusion,
      tint: tint,
      accent: accent,
      emissive: emissive,
      gloss: gloss,
      sway: sway,
      windPhase: windPhase,
      windFlutter: windFlutter,
      joints: joints,
      weights: weights,
      texCoords: texCoords,
      aabb: aabb,
    );
  }
}
