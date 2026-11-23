import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

/// {@template notifying_vector_4}
/// Extension of the standard [Vector4] class, implementing the [ChangeNotifier]
/// functionality. This allows any interested party to be notified when the
/// value of this vector changes.
///
/// This class can be used as a regular [Vector4] class. However, if you do
/// subscribe to notifications, don't forget to eventually unsubscribe in
/// order to avoid resource leaks.
///
/// Direct modification of this vector's [storage] is not allowed.
///
/// Every method of this vector that changes its value notifies; writing the
/// value it already has notifies nobody. Functions that write into a vector
/// passed to them as an output argument, such as `Matrix4.transformed`,
/// bypass the notification; set the value through this vector's own methods
/// instead.
/// {@endtemplate}
class NotifyingVector4.zero() extends Vector4 with ChangeNotifier {
  /// {@macro notifying_vector_4}
  ///
  /// Constructs a vector using the raw values [x], [y], [z] and [w].
  factory NotifyingVector4(double x, double y, double z, double w) =>
      NotifyingVector4.zero()..setValues(x, y, z, w);

  /// {@macro notifying_vector_4}
  ///
  /// Create a zero vector.
  this : super.zero();

  /// {@macro notifying_vector_4}
  ///
  /// Create a vector whose values are all [v].
  factory NotifyingVector4.all(double v) => NotifyingVector4.zero()..splat(v);

  /// {@macro notifying_vector_4}
  ///
  /// Create a copy of the [other] vector.
  factory NotifyingVector4.copy(Vector4 other) =>
      NotifyingVector4.zero()..setFrom(other);

  @override
  void setValues(double x, double y, double z, double w) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setValues(x, y, z, w);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setFrom(Vector4 other) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setFrom(other);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setZero() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setZero();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setIdentity() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setIdentity();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void splat(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.splat(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void operator []=(int i, double v) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super[i] = v;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void applyMatrix4(Matrix4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.applyMatrix4(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void add(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.add(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void addScaled(Vector4 arg, double factor) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.addScaled(arg, factor);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void sub(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.sub(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void multiply(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.multiply(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void div(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.div(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void scale(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.scale(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void negate() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.negate();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void absolute() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.absolute();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void clamp(Vector4 min, Vector4 max) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.clamp(min, max);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void clampScalar(double min, double max) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.clampScalar(min, max);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void floor() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.floor();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void ceil() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.ceil();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void round() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.round();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void roundToZero() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.roundToZero();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void copyFromArray(List<double> array, [int offset = 0]) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.copyFromArray(array, offset);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set length(double value) {
    if (value == 0) {
      // Vector4 sets a zero length with setZero, which notifies.
      setZero();
      return;
    }
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.length = value;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  double normalize() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    final length = super.normalize();
    _notifyIfChanged(x0, y0, z0, w0);
    return length;
  }

  @override
  set x(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.x = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set y(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.y = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set z(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.z = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set w(double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.w = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xy(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xz(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xw(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yx(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yz(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yw(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zx(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zy(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zw(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wx(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wy(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wz(Vector2 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xyz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xyz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xyw(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xyw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xzy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xzy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xzw(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xzw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xwy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xwy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xwz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xwz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yxz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yxz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yxw(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yxw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yzx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yzx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yzw(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yzw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set ywx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.ywx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set ywz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.ywz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zxy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zxy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zxw(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zxw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zyx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zyx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zyw(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zyw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zwx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zwx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zwy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zwy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wxy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wxy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wxz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wxz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wyx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wyx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wyz(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wyz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wzx(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wzx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wzy(Vector3 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wzy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xyzw(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xyzw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xywz(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xywz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xzyw(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xzyw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xzwy(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xzwy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xwyz(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xwyz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set xwzy(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.xwzy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yxzw(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yxzw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yxwz(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yxwz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yzxw(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yzxw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set yzwx(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.yzwx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set ywxz(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.ywxz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set ywzx(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.ywzx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zxyw(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zxyw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zxwy(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zxwy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zyxw(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zyxw = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zywx(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zywx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zwxy(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zwxy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set zwyx(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.zwyx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wxyz(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wxyz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wxzy(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wxzy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wyxz(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wyxz = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wyzx(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wyzx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wzxy(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wzxy = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set wzyx(Vector4 arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.wzyx = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  /// The modifiable storage, read to tell whether a write changed the value.
  late final Float32List _values = super.storage;

  /// Notifies the listeners when the value differs from (x0, y0, z0, w0),
  /// the value before a write: writing the current value again notifies
  /// nobody.
  void _notifyIfChanged(double x0, double y0, double z0, double w0) {
    final values = _values;
    if (values[0] != x0 ||
        values[1] != y0 ||
        values[2] != z0 ||
        values[3] != w0) {
      notifyListeners();
    }
  }

  @override
  Float32List get storage => _unmodifiableStorage;
  late final Float32List _unmodifiableStorage = super.storage
      .asUnmodifiableView();
}
