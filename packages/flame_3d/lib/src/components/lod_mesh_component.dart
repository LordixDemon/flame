import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart' show Ray, RayHit3D, World3D;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// {@template mesh_lod_level}
/// One detail tier of a [LodMeshComponent], ordered from highest detail to
/// lowest detail.
///
/// A level matches when the object's camera distance is at most [maxDistance]
/// AND its projected clip-space height ratio (`projectedHeight / viewportHeight`)
/// is at least [minScreenHeightRatio]. The last level in the list acts as a
/// fallback when coarser thresholds are exceeded.
/// {@endtemplate}
class const MeshLodLevel({
  /// The mesh drawn at this detail tier.
  required final Mesh mesh,

  /// Maximum distance from the camera at which this tier is used.
  final double maxDistance = double.infinity,

  /// Minimum fraction of viewport height (`0..1+`) occupied by the component's
  /// bounding box for this tier to be selected (`0` disables screen-size
  /// gating).
  final double minScreenHeightRatio = 0.0,
});

/// {@template lod_mesh_component}
/// An [Object3D] that automatically selects one of its [levels] based on camera
/// distance and projected screen coverage, with an optional simplified
/// [shadowMesh] for directional shadow passes.
/// {@endtemplate}
class LodMeshComponent({
  required final List<MeshLodLevel> levels,
  Mesh? shadowMesh,
  bool lowestLodInShadowPass = false,
  double hysteresis = 0.0,
  Color color = const Color(0xFFFFFFFF),
  Vector4? instanceData,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
}) extends Object3D {
  /// {@macro lod_mesh_component}
  this {
    if (levels.isEmpty) {
      throw ArgumentError.value(levels, 'levels', 'Must not be empty');
    }
    var needsProj = false;
    for (var i = 0; i < levels.length - 1; i++) {
      if (levels[i].minScreenHeightRatio > 0) {
        needsProj = true;
        break;
      }
    }
    _needsScreenRatio = needsProj;
    this.instanceData.addListener(_onInstanceDataChanged);
  }

  late final bool _needsScreenRatio;
  double _hysteresis = hysteresis.clamp(0.0, 0.5);

  /// Fractional hysteresis band `[0..0.5]` resisting rapid switching at tier
  /// boundaries (`0.0` disables hysteresis).
  double get hysteresis => _hysteresis;
  set hysteresis(double value) {
    final clamped = value.clamp(0.0, 0.5);
    if (clamped == _hysteresis) {
      return;
    }
    _hysteresis = clamped;
    _lodCacheEpoch = -1;
    markDrawDirty(shadows: castsShadows);
  }

  /// A simplified mesh drawn in shadow passes instead of the selected level,
  /// or `null`. Changing it marks the enclosing [World3D] dirty.
  Mesh? get shadowMesh => _shadowMesh;
  set shadowMesh(Mesh? value) {
    if (identical(value, _shadowMesh)) {
      return;
    }
    _shadowMesh = value;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  Mesh? _shadowMesh = shadowMesh;

  /// Whether shadow passes draw the last (coarsest) level when there is no
  /// [shadowMesh]. Changing it marks the enclosing [World3D] dirty.
  bool get lowestLodInShadowPass => _lowestLodInShadowPass;
  set lowestLodInShadowPass(bool value) {
    if (value == _lowestLodInShadowPass) {
      return;
    }
    _lowestLodInShadowPass = value;
    markDrawDirty(shadows: castsShadows);
  }

  bool _lowestLodInShadowPass = lowestLodInShadowPass;

  /// The per-instance color forwarded to shaders. Changing it marks the
  /// enclosing [World3D] dirty.
  Color get color => _color;
  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markDrawDirty(shadows: false);
  }

  Color _color = color;

  /// Four floats of per-instance data forwarded to shaders; every change,
  /// in place too, marks the enclosing [World3D] dirty.
  final NotifyingVector4 instanceData = NotifyingVector4.zero()
    ..setFrom(instanceData ?? Vector4.zero());

  void _onInstanceDataChanged() => markDrawDirty(shadows: false);

  int _lastSelectedLevel = 0;
  int _lodCacheEpoch = -1;
  int _lodWorldVersion = -1;
  bool _lodCenterDirty = true;
  double _lodCx = 0;
  double _lodCy = 0;
  double _lodCz = 0;

  @override
  void markAabbDirty() {
    _lodCenterDirty = true;
    _lodCacheEpoch = -1;
    _lodWorldVersion = -1;
    super.markAabbDirty();
  }

  /// Index of the [levels] entry drawn in the most recent main pass.
  int get lastSelectedLevel => _lastSelectedLevel;

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == LodMeshComponent;

  @override
  Aabb3? computeLocalAabb() {
    final box = Aabb3.copy(levels.first.mesh.aabb);
    for (var i = 1; i < levels.length; i++) {
      box.hull(levels[i].mesh.aabb);
    }
    if (shadowMesh case final sm?) {
      box.hull(sm.aabb);
    }
    return box;
  }

  @override
  void draw(covariant RenderContext3D context) {
    if (context.isShadowPass) {
      // Without a shadow mesh, cast from the level the main camera of this
      // frame selects (see RenderContext3D.viewerPosition).
      final caster =
          shadowMesh ??
          (lowestLodInShadowPass
              ? levels.last.mesh
              : levels[_selectLevel(context)].mesh);
      context.drawMesh(
        caster,
        transform: worldTransformMatrix,
        color: color,
        instanceData: instanceData,
        mirrored: hasNegativeScale,
      );
      return;
    }

    final index = _selectLevel(context);
    _lastSelectedLevel = index;
    context.drawMesh(
      levels[index].mesh,
      transform: worldTransformMatrix,
      color: color,
      instanceData: instanceData,
      mirrored: hasNegativeScale,
    );
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    return RayHit3D.intersectMesh(
      owner: this,
      mesh: levels[_lastSelectedLevel].mesh,
      modelMatrix: worldTransformMatrix,
      worldRay: worldRay,
      maxDistance: maxDistance,
      cullMode: cullMode,
    );
  }

  int _selectLevel(RenderContext3D context) {
    final count = levels.length;
    if (count == 1) {
      return 0;
    }
    final viewerEpoch = context.viewerEpoch;
    final worldVersion = worldTransformVersion;
    if (!_lodCenterDirty &&
        _lodWorldVersion == worldVersion &&
        _lodCacheEpoch == viewerEpoch) {
      return _lastSelectedLevel.clamp(0, count - 1);
    }
    final box = aabb;
    if (_lodCenterDirty || _lodWorldVersion != worldVersion) {
      _lodCx = 0.5 * (box.min.x + box.max.x);
      _lodCy = 0.5 * (box.min.y + box.max.y);
      _lodCz = 0.5 * (box.min.z + box.max.z);
      _lodCenterDirty = false;
      _lodWorldVersion = worldVersion;
    }
    // The viewer, not the pass's camera: in a shadow pass that is the
    // light's view.
    final cam = context.viewerPosition;
    final dx = _lodCx - cam.x;
    final dy = _lodCy - cam.y;
    final dz = _lodCz - cam.z;
    final dist2 = dx * dx + dy * dy + dz * dz;

    var selected = count - 1;
    final h = _hysteresis;
    if (!_needsScreenRatio && h <= 0) {
      for (var i = 0; i < count - 1; i++) {
        final maxDist = levels[i].maxDistance;
        if (maxDist.isInfinite || dist2 <= maxDist * maxDist) {
          selected = i;
          break;
        }
      }
    } else {
      final dist = math.sqrt(dist2);
      var screenRatio = 1.0;
      if (_needsScreenRatio) {
        final vp = context.viewerViewProjection.storage;
        var minNdcY = double.infinity;
        var maxNdcY = double.negativeInfinity;
        final bMinX = box.min.x;
        final bMaxX = box.max.x;
        final bMinY = box.min.y;
        final bMaxY = box.max.y;
        final bMinZ = box.min.z;
        final bMaxZ = box.max.z;
        for (var corner = 0; corner < 8; corner++) {
          final x = (corner & 1) == 0 ? bMinX : bMaxX;
          final y = (corner & 2) == 0 ? bMinY : bMaxY;
          final z = (corner & 4) == 0 ? bMinZ : bMaxZ;
          final clipY = vp[1] * x + vp[5] * y + vp[9] * z + vp[13];
          final clipW = vp[3] * x + vp[7] * y + vp[11] * z + vp[15];
          final ndcY = clipW.abs() > 1e-6 ? clipY / clipW : clipY;
          if (ndcY < minNdcY) {
            minNdcY = ndcY;
          }
          if (ndcY > maxNdcY) {
            maxNdcY = ndcY;
          }
        }
        // Clip Y spans `[-1, 1]` (`2.0` full height).
        screenRatio = 0.5 * math.max(0.0, maxNdcY - minNdcY);
      }
      final prev = _lastSelectedLevel.clamp(0, count - 1);
      for (var i = 0; i < count - 1; i++) {
        final level = levels[i];
        var distLimit = level.maxDistance;
        var ratioLimit = level.minScreenHeightRatio;
        if (h > 0 && !distLimit.isInfinite) {
          distLimit *= i < prev ? (1.0 - h) : (1.0 + h);
          ratioLimit *= i < prev ? (1.0 + h) : (1.0 - h);
        }
        if (dist <= distLimit && screenRatio >= ratioLimit) {
          selected = i;
          break;
        }
      }
    }
    _lodCacheEpoch = viewerEpoch;
    return selected;
  }
}
