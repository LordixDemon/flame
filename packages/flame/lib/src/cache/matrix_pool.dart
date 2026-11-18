import 'dart:typed_data' show Float32List, Float64List;
import 'dart:ui';

class MatrixPool() {
  static final List<Float64List> _pool = [];
  static const int _bufferSize = 16;

  static Float64List getBuffer() {
    if (_pool.isEmpty) {
      return Float64List(_bufferSize);
    }
    return _pool.removeLast();
  }

  static void releaseBuffer(Float64List buffer) {
    _pool.add(buffer);
  }
}

/// The 64-bit copy of a 32-bit matrix that [canvasTransform] and
/// [pathTransform] hand to the engine.
///
/// One buffer is enough: `Canvas.transform` and `Path.transform` read the
/// matrix synchronously and keep no reference to it. A pool of buffers would
/// hand out this same buffer every time anyway, and taking it out of a list
/// and putting it back makes the list drop and regrow its storage on every
/// call.
final Float64List _scratch = Float64List(16);

/// Whether [m] only translates in the plane: everything but the entries 12
/// and 13 (the translation) is the identity.
bool _isTranslation(Float32List m) {
  return m[0] == 1 &&
      m[1] == 0 &&
      m[2] == 0 &&
      m[3] == 0 &&
      m[4] == 0 &&
      m[5] == 1 &&
      m[6] == 0 &&
      m[7] == 0 &&
      m[8] == 0 &&
      m[9] == 0 &&
      m[10] == 1 &&
      m[11] == 0 &&
      m[14] == 0 &&
      m[15] == 1;
}

/// Applies Canvas.transform to a Float64List buffer,
/// allowing the Matrix4 and Lists to be 32 bit.
///
/// A matrix that only translates, which is what most components have, is
/// applied with `Canvas.translate` instead: the same transform, for a much
/// cheaper call. The identity is not applied at all, as the canvas would do
/// nothing with it.
void canvasTransform(Canvas canvas, Float32List matrix4) {
  if (_isTranslation(matrix4)) {
    final dx = matrix4[12];
    final dy = matrix4[13];
    // `Canvas.transform` asserts this for every entry of the matrix.
    assert(dx.isFinite && dy.isFinite, 'Matrix4 entries must be finite.');
    if (dx != 0 || dy != 0) {
      canvas.translate(dx, dy);
    }
    return;
  }
  final buffer = _scratch;
  for (var i = 0; i < 16; i++) {
    buffer[i] = matrix4[i];
  }
  canvas.transform(buffer);
}

/// Applies Path.transform to a Float64List buffer,
/// allowing the Matrix4 and Lists to be 32 bit.
Path pathTransform(Path path, Float32List matrix4) {
  final buffer = _scratch;
  for (var i = 0; i < 16; i++) {
    buffer[i] = matrix4[i];
  }
  return path.transform(buffer);
}
