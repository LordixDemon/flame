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

/// Shared camera-pass apply-cache tracking [Material.version], active
/// vertex and fragment [Shader]s + generations, and `(context, cameraPass)`.
@internal
final class CameraPassApplyCache() {
  int _appliedVersion = -1;
  Shader? _appliedVert;
  int _appliedVertGen = -1;
  Shader? _appliedFrag;
  int _appliedFragGen = -1;
  RenderContext? _appliedContext;
  int _appliedCameraPass = -1;

  /// Invalidates any cached apply signature.
  void invalidate() {
    _appliedVersion = -1;
  }

  /// Returns `true` when material [version] and compiled [vertexShader] /
  /// [fragmentShader] match the previous upload.
  bool isShaderAndVersionValid(
    int version,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    return _appliedVersion == version &&
        identical(_appliedVert, vertexShader) &&
        _appliedVertGen == vertexShader.generation &&
        identical(_appliedFrag, fragmentShader) &&
        _appliedFragGen == fragmentShader.generation;
  }

  /// Returns `true` when shaders, [version], [context], and `cameraPass` all
  /// match the previous upload.
  bool isValid(
    RenderContext context,
    int version,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    return isShaderAndVersionValid(version, vertexShader, fragmentShader) &&
        identical(_appliedContext, context) &&
        context is RenderContext3D &&
        _appliedCameraPass == context.cameraPass;
  }

  /// Records [context], [version], [vertexShader], and [fragmentShader] as
  /// cleanly uploaded.
  void record(
    RenderContext context,
    int version,
    Shader vertexShader,
    Shader fragmentShader,
  ) {
    _appliedVersion = version;
    _appliedVert = vertexShader;
    _appliedVertGen = vertexShader.generation;
    _appliedFrag = fragmentShader;
    _appliedFragGen = fragmentShader.generation;
    _appliedContext = context;
    if (context is RenderContext3D) {
      _appliedCameraPass = context.cameraPass;
    }
  }
}

/// Single-slot identity cache mapping `(VertexLayout, key)` to a compiled
/// vertex [Shader], eliminating repeated attribute lookups on homogenous draws.
@internal
final class VertexShaderLayoutCache() {
  VertexLayout? _lastLayout;
  int _lastKey = 0;
  Shader? _lastShader;

  /// Returns the cached shader if [layout] is identical to the last entry and
  /// [key] matches, otherwise `null`.
  @pragma('vm:prefer-inline')
  Shader? lookup(VertexLayout layout, [int key = 0]) {
    if (identical(layout, _lastLayout) && key == _lastKey) {
      return _lastShader;
    }
    return null;
  }

  /// Stores [shader] for `(layout, key)` and returns [shader].
  @pragma('vm:prefer-inline')
  Shader store(VertexLayout layout, Shader shader, [int key = 0]) {
    _lastLayout = layout;
    _lastKey = key;
    _lastShader = shader;
    return shader;
  }
}
