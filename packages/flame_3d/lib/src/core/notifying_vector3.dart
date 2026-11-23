import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// {@template notifying_vector_3}
/// Extension of the standard [Vector3] class, implementing the [ChangeNotifier]
/// functionality. This allows any interested party to be notified when the
/// value of this vector changes.
///
/// This class can be used as a regular [Vector3] class. However, if you do
/// subscribe to notifications, don't forget to eventually unsubscribe in
/// order to avoid resource leaks.
///
/// Direct modification of this vector's [storage] is not allowed.
///
/// Every method of this vector that changes its value notifies; writing the
/// value it already has notifies nobody. Functions that write into a vector
/// passed to them as an output argument, such as `Matrix4.transform3`,
/// `Vector3.crossInto` or `Matrix4.decompose`, bypass the notification; set
/// the value through this vector's own methods instead.
/// {@endtemplate}
class NotifyingVector3.zero() extends Vector3 with ChangeNotifier {
  /// {@macro notifying_vector_3}
  ///
  /// Constructs a vector using the raw values [x], [y], and [z].
  factory NotifyingVector3(double x, double y, double z) =>
      NotifyingVector3.zero()..setValues(x, y, z);

  /// {@macro notifying_vector_3}
  ///
  /// Create an empty vector.
  this : super.zero();

  /// {@macro notifying_vector_3}
  ///
  /// Create an vector whose values are all [v].
  factory NotifyingVector3.all(double v) => NotifyingVector3.zero()..splat(v);

  /// {@macro notifying_vector_3}
  ///
  /// Create a copy of the [other] vector.
  factory NotifyingVector3.copy(Vector3 other) =>
      NotifyingVector3.zero()..setFrom(other);

  @override
  void setValues(double x, double y, double z) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.setValues(x, y, z);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void setFrom(Vector3 other) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.setFrom(other);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void setZero() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.setZero();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void splat(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.splat(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void operator []=(int i, double v) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super[i] = v;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set length(double l) {
    if (l == 0) {
      // Vector3 sets a zero length with setZero, which notifies.
      setZero();
      return;
    }
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.length = l;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  double normalize() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final l = super.normalize();
    _notifyIfChanged(x0, y0, z0);
    return l;
  }

  @override
  void postmultiply(Matrix3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.postmultiply(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void reflect(Vector3 normal) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.reflect(normal);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void applyProjection(Matrix4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.applyProjection(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  // Vector3.applyAxisAngle delegates to applyQuaternion, which notifies.
  @override
  void applyQuaternion(Quaternion arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.applyQuaternion(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void applyMatrix3(Matrix3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.applyMatrix3(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void applyMatrix4(Matrix4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.applyMatrix4(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void add(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.add(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void addScaled(Vector3 arg, double factor) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.addScaled(arg, factor);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void sub(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.sub(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void multiply(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.multiply(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void divide(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.divide(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void scale(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.scale(arg);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void negate() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.negate();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void absolute() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.absolute();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void clamp(Vector3 min, Vector3 max) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.clamp(min, max);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void clampScalar(double min, double max) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.clampScalar(min, max);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void floor() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.floor();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void ceil() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.ceil();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void round() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.round();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void roundToZero() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.roundToZero();
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  void copyFromArray(List<double> array, [int offset = 0]) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.copyFromArray(array, offset);
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set xy(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.xy = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set xz(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.xz = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set yx(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.yx = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set yz(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.yz = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set zx(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.zx = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set zy(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.zy = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set xyz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.xyz = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set xzy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.xzy = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set yxz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.yxz = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set yzx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.yzx = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set zxy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.zxy = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set zyx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.zyx = arg;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set x(double x) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.x = x;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set y(double y) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.y = y;
    _notifyIfChanged(x0, y0, z0);
  }

  @override
  set z(double z) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    super.z = z;
    _notifyIfChanged(x0, y0, z0);
  }

  /// The modifiable storage, read to tell whether a write changed the value.
  late final Float32List _values = super.storage;

  /// Notifies the listeners when the value differs from (x0, y0, z0),
  /// the value before a write: writing the current value again notifies
  /// nobody.
  void _notifyIfChanged(double x0, double y0, double z0) {
    final values = _values;
    if (values[0] != x0 || values[1] != y0 || values[2] != z0) {
      notifyListeners();
    }
  }

  @override
  Float32List get storage => _unmodifiableStorage;
  late final Float32List _unmodifiableStorage = super.storage
      .asUnmodifiableView();
}
