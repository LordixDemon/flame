import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// Shared single-fragment apply-cache state for materials whose uniform uploads
/// depend on [Material.version] and the active fragment [Shader].
@internal
final class SimpleApplyCache() {
  int _appliedVersion = -1;
  Shader? _appliedFrag;
  int _appliedFragGen = -1;

  /// Invalidates any cached apply signature.
  void invalidate() {
    _appliedVersion = -1;
  }

  /// Returns `true` when [version] and [fragmentShader] match the last recorded
  /// apply.
  bool isValid(int version, Shader fragmentShader) {
    return _appliedVersion == version &&
        identical(_appliedFrag, fragmentShader) &&
        _appliedFragGen == fragmentShader.generation;
  }

  /// Records [version] and [fragmentShader] as cleanly uploaded.
  void record(int version, Shader fragmentShader) {
    _appliedVersion = version;
    _appliedFrag = fragmentShader;
    _appliedFragGen = fragmentShader.generation;
  }
}

/// Shared multi-variant apply-cache tracking [Material.version], the active
/// fragment [Shader], an optional device generation, and up to `31` known
/// vertex shader variant slots (plus 1 custom vertex shader slot).
@internal
final class MultiVariantApplyCache(
  int variantCount, {
  final bool trackDeviceGeneration = false,
}) {
  int _appliedVersion = -1;
  Shader? _appliedFrag;
  int _appliedFragGen = -1;
  int _appliedVertMask = 0;
  int _appliedDeviceGen = -1;
  final List<int> _appliedVarGens = List<int>.filled(variantCount, -1);
  Shader? _appliedCustomVert;
  int _appliedCustomVertGen = -1;

  /// Invalidates all cached vertex variants and custom shader state.
  void invalidate() {
    _appliedVersion = -1;
    _appliedVertMask = 0;
    _appliedCustomVert = null;
  }

  /// Returns `true` when [version], [fragmentShader], and [vertexShader] (at
  /// [variantSlot], or `-1` for custom) were already uploaded cleanly.
  bool isValid({
    required int version,
    required Shader vertexShader,
    required Shader fragmentShader,
    required int variantSlot,
  }) {
    if (_appliedVersion != version ||
        !identical(_appliedFrag, fragmentShader) ||
        _appliedFragGen != fragmentShader.generation) {
      return false;
    }
    if (trackDeviceGeneration &&
        _appliedDeviceGen != GpuBackend.deviceGeneration) {
      return false;
    }
    if (variantSlot < 0) {
      return identical(_appliedCustomVert, vertexShader) &&
          _appliedCustomVertGen == vertexShader.generation;
    }
    return (_appliedVertMask & (1 << variantSlot)) != 0 &&
        _appliedVarGens[variantSlot] == vertexShader.generation;
  }

  /// Records [version], [fragmentShader], and [vertexShader] ([variantSlot])
  /// as cleanly uploaded.
  void record({
    required int version,
    required Shader vertexShader,
    required Shader fragmentShader,
    required int variantSlot,
  }) {
    final deviceGen = trackDeviceGeneration ? GpuBackend.deviceGeneration : -1;
    if (_appliedVersion != version ||
        !identical(_appliedFrag, fragmentShader) ||
        _appliedFragGen != fragmentShader.generation ||
        (trackDeviceGeneration && _appliedDeviceGen != deviceGen)) {
      _appliedVersion = version;
      _appliedFrag = fragmentShader;
      _appliedFragGen = fragmentShader.generation;
      _appliedDeviceGen = deviceGen;
      _appliedVertMask = 0;
      _appliedCustomVert = null;
    }
    if (variantSlot < 0) {
      _appliedCustomVert = vertexShader;
      _appliedCustomVertGen = vertexShader.generation;
    } else {
      _appliedVertMask |= 1 << variantSlot;
      _appliedVarGens[variantSlot] = vertexShader.generation;
    }
  }
}
