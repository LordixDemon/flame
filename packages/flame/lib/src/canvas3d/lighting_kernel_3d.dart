import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/matcap_shader_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/canvas3d/quaternion_3d.dart';
import 'package:flame/src/canvas3d/scene_environment_3d.dart';
import 'package:meta/meta.dart';

/// Shared zero-allocation 3D vertex lighting, UV mapping, normal transform, and
/// material interning kernel used by both `BatchMeshRenderer3D` and
/// `StaticMeshChunk3D`.
@internal
abstract final class LightingKernel3D._() {
  /// Interns [material] into a deduplicated material slot table (`slot 0` is
  /// `null` default material).
  static int internMaterial(List<Material3D?> table, Material3D? material) {
    if (material == null) {
      return 0;
    }
    for (var i = 1; i < table.length; i++) {
      if (table[i] == material) {
        return i;
      }
    }
    table.add(material);
    return table.length - 1;
  }

  /// Writes a row-major `3x3` rotation matrix into [out] from an explicit
  /// [rotationMatrix3], a unit [rotationQuat], or intrinsic Euler angles.
  static void resolveRotationMatrix3({
    required Float32List out,
    Float32List? rotationMatrix3,
    (double, double, double, double)? rotationQuat,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
  }) {
    if (rotationMatrix3 != null && rotationMatrix3.length >= 9) {
      out.setRange(0, 9, rotationMatrix3);
      return;
    }
    if (rotationQuat != null) {
      final (qx, qy, qz, qw) = rotationQuat;
      Quaternion3D.writeMatrix3(qx, qy, qz, qw, out);
      return;
    }
    Quaternion3D.writeEulerMatrix3(
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      out: out,
    );
  }

  /// Largest share of a mesh's visible projected area that
  /// `minTrianglePixelArea` culling may remove.
  static const double microTriangleAreaBudget = 0.05;

  /// Twice the canvas-space triangle area below which a triangle counts as a
  /// micro-triangle for [minTrianglePixelArea] (`0.0` when disabled).
  ///
  /// [minTrianglePixelArea] is in screen pixels, while projected vertices are
  /// in canvas units that the 2D camera then scales by `camera.camZoom`.
  static double microTriangleThreshold2(
    double minTrianglePixelArea,
    CameraRig3D camera,
  ) {
    if (minTrianglePixelArea <= 0.0) {
      return 0.0;
    }
    final zoom = camera.camZoom;
    final zoom2 = zoom > 1e-6 ? zoom * zoom : 1.0;
    return 2.0 * minTrianglePixelArea / zoom2;
  }

  /// Whether the micro-triangles of one mesh may be dropped: either the whole
  /// visible mesh is smaller than one threshold triangle, or its
  /// micro-triangles together cover at most [microTriangleAreaBudget] of it.
  ///
  /// Dropping them in any other case would open holes: on a densely
  /// tessellated mesh every triangle is small at the same time, yet together
  /// they still cover the pixels of the object. All areas are doubled.
  static bool shouldCullMicroTriangles({
    required double visibleArea2,
    required double microArea2,
    required double minArea2,
  }) {
    return visibleArea2 < minArea2 ||
        microArea2 <= visibleArea2 * microTriangleAreaBudget;
  }

  /// Fast, transcendental-free approximation to `(1 - vz)^2.2` on `[0, 1]`
  /// (`< 0.003` max error vs `math.pow`, zero `exp`/`log` overhead).
  static double fastRimCurve(double clampedVz) {
    final omv = 1.0 - clampedVz;
    if (omv <= 0.0) {
      return 0.0;
    }
    final omv2 = omv * omv;
    return omv2 * (0.6 + 0.4 * math.sqrt(omv));
  }

  /// Evaluates world normal, MatCap UVs, atlas/normalized texture UVs,
  /// hemisphere + Lambertian + rim + optional Fresnel + SoA point lights +
  /// distance/height fog, and writes the shaded vertex attributes directly into
  /// [outVertU], [outVertV], [outVertTexU], [outVertTexV],
  /// [outVertTexPixelSpace], and [outVertColor] at [outSlot].
  static void shadeVertexInto({
    required int vertexIndex,
    required int outSlot,
    required Float32List normals,
    required Float32List rot,
    required double invSx,
    required double invSy,
    required double invSz,
    required double worldPosX,
    required double worldPosY,
    required double worldPosZ,
    required double viewDepth,
    required CameraRig3D camera,
    required DirectionalLight3D light,
    required SceneEnvironment3D? environment,
    required double tintR,
    required double tintG,
    required double tintB,
    required double tintA,
    required double emissive,
    required Float32List outVertU,
    required Float32List outVertV,
    required Float32List outVertTexU,
    required Float32List outVertTexV,
    required Uint8List outVertTexPixelSpace,
    required Int32List outVertColor,
    Float32List? uvs,
    Rect? uvRectPx,
    Float32List? ambientOcclusion,
    Int32List? vertexColors,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
  }) {
    final pIdx = vertexIndex * 3;
    final snx = normals[pIdx] * invSx;
    final sny = normals[pIdx + 1] * invSy;
    final snz = normals[pIdx + 2] * invSz;
    var wnx = rot[0] * snx + rot[1] * sny + rot[2] * snz;
    var wny = rot[3] * snx + rot[4] * sny + rot[5] * snz;
    var wnz = rot[6] * snx + rot[7] * sny + rot[8] * snz;
    final nLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
    if (nLen > 1e-7) {
      final invN = 1.0 / nLen;
      wnx *= invN;
      wny *= invN;
      wnz *= invN;
    }

    const matCapRes = MatCapShader3D.resolution;
    final (vx, vy, vz) = camera.worldNormalToView(wnx, wny, wnz);
    final u = (vx * 0.48 + 0.5).clamp(0.02, 0.98) * matCapRes;
    final texV = (0.5 - vy * 0.48).clamp(0.02, 0.98) * matCapRes;

    final double meshTexU;
    final double meshTexV;
    final int texPixelSpace;
    if (uvs != null) {
      final uvBase = vertexIndex * 2;
      if (uvRectPx != null) {
        meshTexU = uvRectPx.left + uvs[uvBase] * uvRectPx.width;
        meshTexV = uvRectPx.top + uvs[uvBase + 1] * uvRectPx.height;
        texPixelSpace = 1;
      } else {
        meshTexU = uvs[uvBase];
        meshTexV = uvs[uvBase + 1];
        texPixelSpace = 0;
      }
    } else {
      meshTexU = u;
      meshTexV = texV;
      texPixelSpace = 1;
    }

    final skyC = light.skyColor;
    final gndC = light.groundColor;
    final sunC = light.sunColor;
    final skyR = skyC.r;
    final skyG = skyC.g;
    final skyB = skyC.b;
    final ambInt = light.ambientIntensity;
    final difInt = light.diffuseIntensity;

    final hemiMix = (wnz * 0.5 + 0.5).clamp(0.0, 1.0);
    final ambR = (gndC.r + (skyR - gndC.r) * hemiMix) * ambInt;
    final ambG = (gndC.g + (skyG - gndC.g) * hemiMix) * ambInt;
    final ambB = (gndC.b + (skyB - gndC.b) * hemiMix) * ambInt;

    final nDotL = math.max(
      0.0,
      wnx * light.dirX + wny * light.dirY + wnz * light.dirZ,
    );
    final clampedVz = vz.clamp(0.0, 1.0);
    final rim = fastRimCurve(clampedVz) * light.rimIntensity;
    final fresnel = (rimColor != null && rimHighlightIntensity > 0.0)
        ? (1.0 - clampedVz) * (1.0 - clampedVz) * rimHighlightIntensity
        : 0.0;
    final ao = ambientOcclusion != null ? ambientOcclusion[vertexIndex] : 1.0;

    var baseR = tintR;
    var baseG = tintG;
    var baseB = tintB;
    var baseA = tintA;
    if (vertexColors != null) {
      final vc = vertexColors[vertexIndex];
      baseA *= ((vc >>> 24) & 0xFF) / 255.0;
      baseR *= ((vc >>> 16) & 0xFF) / 255.0;
      baseG *= ((vc >>> 8) & 0xFF) / 255.0;
      baseB *= (vc & 0xFF) / 255.0;
    }

    final addRimR = fresnel > 0.0 ? rimColor!.r * fresnel : 0.0;
    final addRimG = fresnel > 0.0 ? rimColor!.g * fresnel : 0.0;
    final addRimB = fresnel > 0.0 ? rimColor!.b * fresnel : 0.0;

    var ptR = 0.0;
    var ptG = 0.0;
    var ptB = 0.0;
    if (environment != null && environment.pointLightCount > 0) {
      (ptR, ptG, ptB) = environment.samplePointLights(
        wx: worldPosX,
        wy: worldPosY,
        wz: worldPosZ,
        nx: wnx,
        ny: wny,
        nz: wnz,
      );
    }

    var lr =
        (baseR * (ambR * ao + sunC.r * nDotL * difInt + ptR + emissive) +
                rim * skyR +
                addRimR)
            .clamp(0.0, 1.0);
    var lg =
        (baseG * (ambG * ao + sunC.g * nDotL * difInt + ptG + emissive) +
                rim * skyG +
                addRimG)
            .clamp(0.0, 1.0);
    var lb =
        (baseB * (ambB * ao + sunC.b * nDotL * difInt + ptB + emissive) +
                rim * skyB +
                addRimB)
            .clamp(0.0, 1.0);

    if (environment != null && environment.fogEnabled) {
      final fog = environment.computeFogFactor(
        viewDepth: viewDepth,
        worldZ: worldPosZ,
      );
      if (fog > 0.0) {
        lr += (environment.fogColor.r - lr) * fog;
        lg += (environment.fogColor.g - lg) * fog;
        lb += (environment.fogColor.b - lb) * fog;
      }
    }

    outVertU[outSlot] = u;
    outVertV[outSlot] = texV;
    outVertTexU[outSlot] = meshTexU;
    outVertTexV[outSlot] = meshTexV;
    outVertTexPixelSpace[outSlot] = texPixelSpace;
    outVertColor[outSlot] =
        ((baseA * 255.0).round().clamp(0, 255) << 24) |
        ((lr * 255.0).round().clamp(0, 255) << 16) |
        ((lg * 255.0).round().clamp(0, 255) << 8) |
        (lb * 255.0).round().clamp(0, 255);
  }
}
