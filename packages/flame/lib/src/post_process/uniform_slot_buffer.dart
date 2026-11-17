import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Writes float uniforms, slot by slot, to a [ui.FragmentShader] or to a
/// custom uniform sink.
///
/// `FragmentShader.setFloat` only stores the value in a float list on the
/// Dart side; nothing crosses into the engine until the shader is drawn. A
/// cache lookup would cost more than the store it could save, so [setFloat]
/// and the vector helpers pass every value straight through to the shader.
/// They are counted in [uploadedCount] and never in [skippedCount].
///
/// [setFloatCustom] writes to an arbitrary uploader, whose cost is not
/// known. That path is dirty-checked: the uploader is skipped
/// ([skippedCount]) while the slot's IEEE-754 32-bit float value is the one
/// last sent to the same target.
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

  /// Number of values written: every [setFloat], and every
  /// [setFloatCustom] whose value differed from the cached one.
  int get uploadedCount => _uploadedCount;

  /// Number of [setFloatCustom] writes skipped because the slot already held
  /// the value.
  int get skippedCount => _skippedCount;

  /// Current slot capacity of the dirty cache used by [setFloatCustom].
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

  /// Writes [value] into uniform slot [index] on [shader].
  ///
  /// The write always happens (see the class documentation), so this always
  /// returns `true`.
  bool setFloat(ui.FragmentShader shader, int index, double value) {
    shader.setFloat(index, value);
    _uploadedCount++;
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

  /// Marks all slots cached for [setFloatCustom] dirty, so the next write
  /// to each of them reaches the uploader.
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
