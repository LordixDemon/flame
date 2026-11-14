import 'dart:ui' as ui;

import 'package:flame/src/canvas3d/matcap_shader_3d.dart';
import 'package:meta/meta.dart';

/// Shading mode for a [Material3D] inside `BatchMeshRenderer3D`.
enum MaterialShading3D() {
  /// Pure vertex-lit triangle colors without any UV shader sampling.
  unshaded,

  /// Spherical view-space normal MatCap shading via [MatCapShader3D].
  matCap,

  /// UV-mapped texture/procedural shader sampling (`mesh.uvs` / `uvRectPx`).
  texture,
}

/// Immutable per-mesh or per-chunk 3D surface material descriptor enabling
/// `BatchMeshRenderer3D` to globally depth-sort triangles from different
/// textures, MatCap presets, and [ui.BlendMode]s (such as opaque buildings,
/// metallic MatCap props, and `BlendMode.plus` energy shields) in a single
/// scene without breaking 3D occlusion order.
@immutable
class const Material3D._({
  required this.shading,
  required this.blendMode,
  this.matCapPreset,
  this.textureShader,
  this.textureWidth = 1.0,
  this.textureHeight = 1.0,
}) {
  /// Pure vertex-colored material (defaults to opaque `BlendMode.dst`; pass
  /// `BlendMode.plus` or `BlendMode.srcOver` for additive/translucent 3D VFX).
  const Material3D.unshaded({
    ui.BlendMode blendMode = ui.BlendMode.dst,
  }) : this._(
         shading: MaterialShading3D.unshaded,
         blendMode: blendMode,
       );

  /// Spherical MatCap material using [preset] (resolved from the
  /// `MatCapShader3D` passed to `BatchMeshRenderer3D.flushBatch`).
  const Material3D.matCap(
    MatCapPreset3D preset, {
    ui.BlendMode blendMode = ui.BlendMode.modulate,
  }) : this._(
         shading: MaterialShading3D.matCap,
         matCapPreset: preset,
         blendMode: blendMode,
       );

  /// UV-mapped texture or custom `ui.Shader` material.
  ///
  /// Normalized `[0..1]` mesh UVs are scaled by `(textureWidth, textureHeight)`
  /// into pixel coordinates expected by `ui.ImageShader`, whereas pixel-space
  /// `uvRectPx` coordinates are forwarded directly.
  const Material3D.texture(
    ui.Shader shader, {
    double width = 1.0,
    double height = 1.0,
    ui.BlendMode blendMode = ui.BlendMode.modulate,
  }) : this._(
         shading: MaterialShading3D.texture,
         textureShader: shader,
         textureWidth: width,
         textureHeight: height,
         blendMode: blendMode,
       );

  /// Active shading pipeline for triangles carrying this material.
  final MaterialShading3D shading;

  /// Optional [MatCapPreset3D] when [shading] is [MaterialShading3D.matCap].
  final MatCapPreset3D? matCapPreset;

  /// Optional GPU [ui.Shader] when [shading] is [MaterialShading3D.texture].
  final ui.Shader? textureShader;

  /// Width of the bound texture in pixels for normalized `[0..1]` UV scaling.
  final double textureWidth;

  /// Height of the bound texture in pixels for normalized `[0..1]` UV scaling.
  final double textureHeight;

  /// Canvas [ui.BlendMode] passed to `Canvas.drawVertices`.
  final ui.BlendMode blendMode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Material3D &&
          other.shading == shading &&
          other.matCapPreset == matCapPreset &&
          identical(other.textureShader, textureShader) &&
          other.textureWidth == textureWidth &&
          other.textureHeight == textureHeight &&
          other.blendMode == blendMode);

  @override
  int get hashCode => Object.hash(
    shading,
    matCapPreset,
    identityHashCode(textureShader),
    textureWidth,
    textureHeight,
    blendMode,
  );
}
