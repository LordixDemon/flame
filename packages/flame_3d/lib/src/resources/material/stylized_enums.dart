part of 'stylized_material.dart';

/// Where the vertices of a [StylizedMaterial]'s emissive mask take the color
/// they glow with, see [StylizedMaterial.emissiveColorSource].
///
/// The instance colors are exact on every pixel: an instance looks exactly
/// like the same instance drawn with a material whose
/// [StylizedMaterial.emissiveColor] is its glow color. The shader numbers the
/// sources in this order.
enum EmissiveColorSource() {
  /// The material's [StylizedMaterial.emissiveColor], the same for every
  /// instance (the default).
  emissiveColor,

  /// The color of each instance (`MeshComponent.color`), the one that tints
  /// the vertices of the tint mask: a tinted inlay glows in its tint. Its
  /// alpha is not used.
  instanceColor,

  /// The accent of each instance: the [StylizedMaterial.accentPalette] entry
  /// it picks with [StylizedMaterial.packPaletteAndFade], or the material's
  /// [StylizedMaterial.accentColor] without one (or with an index beyond the
  /// palette), the color its accent-masked vertices take.
  accent,

  /// The [StylizedMaterial.rimPalette] entry of each instance, picked with
  /// [StylizedMaterial.packPaletteAndFade]: its color, not its alpha (the
  /// strength of its rim), so an entry of alpha `0` glows without a rim. An
  /// instance without an entry (or with an index beyond the palette) glows
  /// in [StylizedMaterial.emissiveColor].
  rim,
}

/// How a [StylizedMaterial]'s base color texture combines with the vertex
/// color, see [StylizedMaterial.baseColorTextureMode].
enum BaseColorTextureMode() {
  /// The texture multiplies the vertex color, alpha included (the default):
  /// vertex colors tint the texture, white vertices show it as it is.
  multiply,

  /// The texture replaces the vertex color, alpha included: the vertex color
  /// is not used.
  replace,
}

/// The space a [StylizedMaterial]'s wind direction and amplitudes are given
/// in.
enum WindSpace() {
  /// World space: every object sways along the same direction, by the same
  /// distance.
  world,

  /// The model space of each object: the sway turns and scales with the
  /// object, as if it were part of its mesh.
  model,

  /// The direction in world space and the amplitudes scaled by the size of
  /// each object along its up axis ([StylizedMaterial.windUpAxis], in model
  /// space): whatever their orientation, objects sway the same world way,
  /// each in proportion to its height. An object scaled twice along its up
  /// axis sways twice as far.
  /// The direction of the gusts travel in, in world space.
  worldScaled,
}
