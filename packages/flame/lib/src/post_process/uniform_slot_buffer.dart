import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Dirty-checked float32 uniform cache for [ui.FragmentShader] that skips
/// redundant Dart-to-Impeller/Skia FFI `setFloat` calls when a uniform slot's
/// IEEE-754 32-bit float value has not changed since the previous frame.
class UniformSlotBuffer({int initialCapacity = 32}) {
  this : assert(initialCapacity > 0, 'initialCapacity must be positive') {
    final cap = math.max(8, initialCapacity);
    _bits = Uint32List(cap);
    _valid = Uint8List(cap);
  }

  late Uint32List _bits;
  late Uint8List _valid;
  final Float32List _f32Scratch = Float32List(1);
  late final Uint32List _u32Scratch = _f32Scratch.buffer.asUint32List();

  Object? _boundShader;
  int _uploadedCount = 0;
  int _skippedCount = 0;

  /// Number of `shader.setFloat` FFI calls actually transmitted.
  int get uploadedCount => _uploadedCount;

  /// Number of redundant `shader.setFloat` FFI calls skipped via
  /// dirty-checking.
  int get skippedCount => _skippedCount;

  /// Current slot capacity of the backing typed array.
  int get capacity => _bits.length;

  void _ensureCapacity(int index) {
    if (index < _bits.length) {
      return;
    }
    var nextCap = _bits.length;
    while (nextCap <= index) {
      nextCap *= 2;
    }
    final nextBits = Uint32List(nextCap)..setRange(0, _bits.length, _bits);
    final nextValid = Uint8List(nextCap)..setRange(0, _valid.length, _valid);
    _bits = nextBits;
    _valid = nextValid;
  }

  bool _prepareSlot(Object targetIdentity, int index, double value) {
    if (!identical(_boundShader, targetIdentity)) {
      _boundShader = targetIdentity;
      _valid.fillRange(0, _valid.length, 0);
    }
    _ensureCapacity(index);
    _f32Scratch[0] = value;
    final rawBits = _u32Scratch[0];
    if (_valid[index] != 0 && _bits[index] == rawBits) {
      _skippedCount++;
      return false;
    }
    _bits[index] = rawBits;
    _valid[index] = 1;
    _uploadedCount++;
    return true;
  }

  /// Writes [value] into uniform slot [index] on [shader] only if [shader]
  /// changed, the slot has not yet been written, or its 32-bit float bit
  /// pattern differs from the cached value.
  ///
  /// Returns `true` when `shader.setFloat` was invoked, or `false` when
  /// skipped.
  bool setFloat(ui.FragmentShader shader, int index, double value) {
    if (!_prepareSlot(shader, index, value)) {
      return false;
    }
    shader.setFloat(index, value);
    return true;
  }

  /// Dirty-checked float upload targeting a custom [uploader] sink keyed by
  /// [targetIdentity] (useful for custom uniform backends and headless tests).
  bool setFloatCustom(
    Object targetIdentity,
    int index,
    double value,
    void Function(int index, double value) uploader,
  ) {
    if (!_prepareSlot(targetIdentity, index, value)) {
      return false;
    }
    uploader(index, value);
    return true;
  }

  /// Writes a 2-component vector into slots `baseIndex .. baseIndex + 1`.
  void setVec2(ui.FragmentShader shader, int baseIndex, double x, double y) {
    setFloat(shader, baseIndex, x);
    setFloat(shader, baseIndex + 1, y);
  }

  /// Writes a 3-component vector into slots `baseIndex .. baseIndex + 2`.
  void setVec3(
    ui.FragmentShader shader,
    int baseIndex,
    double x,
    double y,
    double z,
  ) {
    setFloat(shader, baseIndex, x);
    setFloat(shader, baseIndex + 1, y);
    setFloat(shader, baseIndex + 2, z);
  }

  /// Writes a 4-component vector into slots `baseIndex .. baseIndex + 3`.
  void setVec4(
    ui.FragmentShader shader,
    int baseIndex,
    double x,
    double y,
    double z,
    double w,
  ) {
    setFloat(shader, baseIndex, x);
    setFloat(shader, baseIndex + 1, y);
    setFloat(shader, baseIndex + 2, z);
    setFloat(shader, baseIndex + 3, w);
  }

  /// Writes normalized RGBA components of [color] into 4 consecutive slots.
  void setColorRgba(ui.FragmentShader shader, int baseIndex, ui.Color color) {
    setVec4(shader, baseIndex, color.r, color.g, color.b, color.a);
  }

  /// Marks all cached uniform slots dirty so the next frame re-uploads them.
  void invalidate() {
    _boundShader = null;
    _valid.fillRange(0, _valid.length, 0);
  }

  /// Resets [uploadedCount] and [skippedCount] telemetry counters to zero.
  void resetCounters() {
    _uploadedCount = 0;
    _skippedCount = 0;
  }
}
