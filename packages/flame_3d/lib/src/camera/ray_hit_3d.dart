import 'dart:math' as math;

import 'package:flame_3d/camera.dart' show Ray;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// {@template ray_hit_3d}
/// A world-space ray intersection against an [Object3D] and one of its
/// [Surface]s.
/// {@endtemplate}
class RayHit3D({
  required final Object3D object,
  required final Surface surface,
  required final double distance,
  required final Vector3 worldPoint,
  required final Vector3 worldNormal,
  required final Vector3 localPoint,
  required final Vector3 localNormal,
  required final int triangleIndex,

  /// The index of [surface] in its mesh, except on a hit on an
  /// `InstancedGroup3D`, where it holds the index of the instance hit, as
  /// [instanceIndex] does (kept for compatibility: read [instanceIndex] for
  /// the instance and [surface] for the surface).
  final int surfaceIndex = 0,

  /// The index of the instance hit in an object that draws instances: an
  /// instance of an `InstancedGroup3D`, an agent of a `SkinnedCrowdBatch3D`.
  /// `null` for the other objects.
  final int? instanceIndex,
}) {
  /// This hit, as a hit on the instance [index] of its [object].
  RayHit3D onInstance(int index, {int? surfaceIndex}) => RayHit3D(
    object: object,
    surface: surface,
    surfaceIndex: surfaceIndex ?? this.surfaceIndex,
    instanceIndex: index,
    distance: distance,
    worldPoint: worldPoint,
    worldNormal: worldNormal,
    localPoint: localPoint,
    localNormal: localNormal,
    triangleIndex: triangleIndex,
  );

  /// Intersects [worldRay] against [mesh] transformed by [modelMatrix],
  /// returning the closest [RayHit3D] on [owner] within [maxDistance], or
  /// `null` when missed.
  static RayHit3D? intersectMesh({
    required Object3D owner,
    required Mesh mesh,
    required Matrix4 modelMatrix,
    required Ray worldRay,
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (!(maxDistance > 0) || mesh.surfaces.isEmpty) {
      return null;
    }
    if (!_prepareLocalRay(modelMatrix, worldRay)) {
      return null;
    }
    RayHit3D? best;
    var limit = maxDistance;
    var i = 0;
    for (final surface in mesh.surfaces) {
      if (surface.indexCount >= 3) {
        final hit = _intersectPreparedSurface(
          owner: owner,
          surface: surface,
          surfaceIndex: i,
          worldRay: worldRay,
          maxDistance: limit,
          cullMode: cullMode ?? surface.material.renderState.cullMode,
        );
        if (hit != null && hit.distance < limit) {
          limit = hit.distance;
          best = hit;
        }
      }
      i++;
    }
    return best;
  }

  /// Intersects [worldRay] against [surface] transformed by [modelMatrix].
  static RayHit3D? intersectSurface({
    required Object3D owner,
    required Surface surface,
    required Matrix4 modelMatrix,
    required Ray worldRay,
    int surfaceIndex = 0,
    double maxDistance = double.infinity,
    CullMode cullMode = CullMode.none,
  }) {
    if (surface.indexCount < 3 || !(maxDistance > 0)) {
      return null;
    }
    if (!_prepareLocalRay(modelMatrix, worldRay)) {
      return null;
    }
    return _intersectPreparedSurface(
      owner: owner,
      surface: surface,
      surfaceIndex: surfaceIndex,
      worldRay: worldRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
    );
  }

  static bool _prepareLocalRay(Matrix4 modelMatrix, Ray worldRay) {
    final s = modelMatrix.storage;
    var invertedRigid = false;
    if (s[3] == 0.0 && s[7] == 0.0 && s[11] == 0.0 && s[15] == 1.0) {
      final c0x = s[0];
      final c0y = s[1];
      final c0z = s[2];
      final c1x = s[4];
      final c1y = s[5];
      final c1z = s[6];
      final c2x = s[8];
      final c2y = s[9];
      final c2z = s[10];
      final l0 = c0x * c0x + c0y * c0y + c0z * c0z;
      final l1 = c1x * c1x + c1y * c1y + c1z * c1z;
      final l2 = c2x * c2x + c2y * c2y + c2z * c2z;
      if ((l0 - 1.0).abs() <= 1e-5 &&
          (l1 - 1.0).abs() <= 1e-5 &&
          (l2 - 1.0).abs() <= 1e-5) {
        final d01 = c0x * c1x + c0y * c1y + c0z * c1z;
        final d02 = c0x * c2x + c0y * c2y + c0z * c2z;
        final d12 = c1x * c2x + c1y * c2y + c1z * c2z;
        if (d01.abs() <= 1e-5 && d02.abs() <= 1e-5 && d12.abs() <= 1e-5) {
          final tx = s[12];
          final ty = s[13];
          final tz = s[14];
          final o = _inverse.storage;
          o[0] = c0x;
          o[4] = c0y;
          o[8] = c0z;
          o[12] = -(c0x * tx + c0y * ty + c0z * tz);
          o[1] = c1x;
          o[5] = c1y;
          o[9] = c1z;
          o[13] = -(c1x * tx + c1y * ty + c1z * tz);
          o[2] = c2x;
          o[6] = c2y;
          o[10] = c2z;
          o[14] = -(c2x * tx + c2y * ty + c2z * tz);
          o[3] = 0.0;
          o[7] = 0.0;
          o[11] = 0.0;
          o[15] = 1.0;
          invertedRigid = true;
        }
      }
    }
    if (!invertedRigid) {
      _inverse.setFrom(modelMatrix);
      if (_inverse.invert().abs() < 1e-15) {
        return false;
      }
    }

    final m = _inverse.storage;
    final ox = worldRay.origin.x;
    final oy = worldRay.origin.y;
    final oz = worldRay.origin.z;
    final dx = worldRay.direction.x;
    final dy = worldRay.direction.y;
    final dz = worldRay.direction.z;

    // Affine transform preserves the ray parameter `t`:
    // `p_local(t) = M^-1 * (o + t * d)`.
    _localRay.origin.setValues(
      m[0] * ox + m[4] * oy + m[8] * oz + m[12],
      m[1] * ox + m[5] * oy + m[9] * oz + m[13],
      m[2] * ox + m[6] * oy + m[10] * oz + m[14],
    );
    _localRay.direction.setValues(
      m[0] * dx + m[4] * dy + m[8] * dz,
      m[1] * dx + m[5] * dy + m[9] * dz,
      m[2] * dx + m[6] * dy + m[10] * dz,
    );
    return true;
  }

  static RayHit3D? _intersectPreparedSurface({
    required Object3D owner,
    required Surface surface,
    required int surfaceIndex,
    required Ray worldRay,
    required double maxDistance,
    required CullMode cullMode,
  }) {
    // `RenderContext3D` flips the GPU winding order when `det < 0`, so outward
    // CCW faces in local space remain front faces in world space, and
    // `(M^-1)^T * localNormal` already preserves outward orientation.
    final localHit = surface.bvh.raycast(
      _localRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
    );
    if (localHit == null) {
      return null;
    }

    final ox = worldRay.origin.x;
    final oy = worldRay.origin.y;
    final oz = worldRay.origin.z;
    final dx = worldRay.direction.x;
    final dy = worldRay.direction.y;
    final dz = worldRay.direction.z;
    final t = localHit.distance;
    final worldPoint = Vector3(ox + dx * t, oy + dy * t, oz + dz * t);

    final m = _inverse.storage;
    final lnx = localHit.normal.x;
    final lny = localHit.normal.y;
    final lnz = localHit.normal.z;
    var wnx = m[0] * lnx + m[1] * lny + m[2] * lnz;
    var wny = m[4] * lnx + m[5] * lny + m[6] * lnz;
    var wnz = m[8] * lnx + m[9] * lny + m[10] * lnz;
    final nLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
    if (nLen > 1e-12) {
      wnx /= nLen;
      wny /= nLen;
      wnz /= nLen;
    }

    return RayHit3D(
      object: owner,
      surface: surface,
      surfaceIndex: surfaceIndex,
      distance: t,
      worldPoint: worldPoint,
      worldNormal: Vector3(wnx, wny, wnz),
      localPoint: localHit.point,
      localNormal: localHit.normal,
      triangleIndex: localHit.triangleIndex,
    );
  }

  static final Matrix4 _inverse = Matrix4.identity();
  static final Ray _localRay = Ray();
}
