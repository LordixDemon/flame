import 'dart:ui' hide FragmentShader;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// {@template spatial_material}
/// A physically based material lit by the scene's ambient, hemisphere, point
/// and directional lights.
///
/// Its base color is [albedoColor] times [albedoTexture], times the vertex
/// color, times the per-instance color (white unless the drawing component
/// sets one). It is drawn instanced. The camera, the lights and the joint
/// matrices of skinned draws are filled by the [RenderContext3D].
///
/// The lighting is physically based, so a directional light needs an
/// intensity of about `3` to light a white surface facing it fully. The result
/// is tone mapped and gamma corrected.
/// {@endtemplate}
class SpatialMaterial({
  /// The material's base color.
  var Color albedoColor = const Color(0xFFFFFFFF),
  Texture? albedoTexture,
  var double metallic = 0.8,
  var double roughness = 0.6,
}) extends Material {
  /// {@macro spatial_material}
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'packages/flame_3d/assets/shaders/spatial_material.shaderbundle',
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'packages/flame_3d/assets/shaders/spatial_material.shaderbundle',
          slots: [
            'albedoTexture',
            'Material',
            RenderContext3D.ambientLightBlock,
            RenderContext3D.lightsBlock,
            RenderContext3D.directionalLightsBlock,
            RenderContext3D.hemisphereLightBlock,
            RenderContext3D.cameraBlock,
          ],
        ),
      );

  /// The texture that will be multiplied by [albedoColor].
  Texture albedoTexture = albedoTexture ?? Texture.standard;

  @override
  void apply(RenderContext context) {
    fragmentShader
      ..setTexture('albedoTexture', albedoTexture)
      ..setColor('Material.albedoColor', albedoColor)
      ..setFloat('Material.metallic', metallic)
      ..setFloat('Material.roughness', roughness);
  }
}
