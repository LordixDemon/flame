import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// The materials a world drew in its last render, with the versions they had
/// when they were drawn, so that the world's scene version follows their
/// changes (see `World3D.sceneVersion`).
///
/// A render notes each material once, when the render context binds it, so
/// the cost is per material bound, not per draw or per instance; reading
/// [version] costs one addition per material of the last render.
@internal
class MaterialTracker() {
  static int _stamps = 0;

  // The materials of the last complete render, and their versions and
  // animation versions when it drew them.
  List<Material?> _materials = [];
  List<int> _versions = [];
  List<int> _animations = [];
  final List<bool> _staticFlags = [];
  int _count = 0;

  // The materials of the render being recorded.
  List<Material?> _nextMaterials = [];
  List<int> _nextVersions = [];
  List<int> _nextAnimations = [];
  final List<bool> _nextStaticFlags = [];
  int _nextCount = 0;
  int _stamp = 0;

  // Keeps [version] from going back when the materials are replaced.
  int _offset = 0;
  int _staticOffset = 0;

  /// The number of materials marked `Material.animated` that the last render
  /// drew.
  int get animatedCount => _animatedCount;
  int _animatedCount = 0;

  /// The number of materials the last render drew.
  int get length => _count;

  /// The material of the last render at [index].
  Material operator [](int index) => _materials[index]!;

  /// A number that increases whenever a material of the last render changes
  /// (and never decreases, also when the materials are replaced).
  int get version {
    var sum = _offset;
    final materials = _materials;
    for (var i = 0; i < _count; i++) {
      sum += materials[i]!.version;
    }
    return sum;
  }

  /// A number like [version] that only tracks non-dynamic materials
  /// (`!material.isStaticCacheDynamic`) so animated water/foliage materials do
  /// not invalidate a cached static scene pass.
  int get staticVersion {
    var sum = _staticOffset;
    final materials = _materials;
    for (var i = 0; i < _count; i++) {
      if (_staticFlags[i]) {
        sum += materials[i]!.version;
      }
    }
    return sum;
  }

  /// Starts noting the materials of a render.
  void begin() {
    _stamp = ++_stamps;
    _nextCount = 0;
    _nextStaticFlags.clear();
  }

  /// Notes that the render being recorded draws [material].
  void note(Material material) {
    if (material.trackingStamp == _stamp) {
      return;
    }
    material.trackingStamp = _stamp;
    final isStatic = !material.isStaticCacheDynamic;
    _nextStaticFlags.add(isStatic);
    final i = _nextCount++;
    if (i == _nextMaterials.length) {
      _nextMaterials.add(material);
      _nextVersions.add(material.version);
      _nextAnimations.add(material.animationVersion);
    } else {
      _nextMaterials[i] = material;
      _nextVersions[i] = material.version;
      _nextAnimations[i] = material.animationVersion;
    }
  }

  /// Ends the render: counts into [stats] the materials of the previous
  /// render that changed since then ([RenderStats.updatedMaterials],
  /// [RenderStats.animatedMaterials]), and keeps the materials of this one,
  /// unless it did not complete.
  void end(RenderStats stats, {required bool completed}) {
    if (!completed) {
      _clearNext();
      return;
    }
    var before = 0;
    var beforeStatic = 0;
    var updated = 0;
    var animated = 0;
    for (var i = 0; i < _count; i++) {
      final material = _materials[i]!;
      final version = material.version;
      before += version;
      if (_staticFlags[i]) {
        beforeStatic += version;
      }
      final changes = version - _versions[i];
      if (changes == 0) {
        continue;
      }
      final animations = material.animationVersion - _animations[i];
      if (changes > animations) {
        updated++;
      } else if (!material.animated) {
        animated++;
      }
    }
    var drawn = 0;
    var drawnStatic = 0;
    var declared = 0;
    for (var i = 0; i < _nextCount; i++) {
      final nextVersion = _nextVersions[i];
      drawn += nextVersion;
      if (_nextStaticFlags[i]) {
        drawnStatic += nextVersion;
      }
      if (_nextMaterials[i]!.animated) {
        declared++;
      }
    }
    stats
      ..updatedMaterials += updated
      ..animatedMaterials += animated + declared;
    // The version stays what it was with the previous materials; it moves
    // on when one of the new ones changed since it was drawn.
    _offset += before - drawn;
    _staticOffset += beforeStatic - drawnStatic;
    _animatedCount = declared;

    final materials = _materials;
    final versions = _versions;
    final animations = _animations;
    final oldCount = _count;
    _materials = _nextMaterials;
    _versions = _nextVersions;
    _animations = _nextAnimations;
    _staticFlags
      ..clear()
      ..addAll(_nextStaticFlags);
    _count = _nextCount;
    _nextMaterials = materials;
    _nextVersions = versions;
    _nextAnimations = animations;
    _nextCount = oldCount;
    _clearNext();
  }

  // Lets go of the materials that are no longer kept.
  void _clearNext() {
    final materials = _nextMaterials;
    for (var i = 0; i < _nextCount; i++) {
      materials[i] = null;
    }
    _nextCount = 0;
  }
}
