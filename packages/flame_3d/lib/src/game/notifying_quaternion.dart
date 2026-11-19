import 'dart:math';

import 'package:flame_3d/game.dart';
import 'package:flutter/foundation.dart';

/// {@template notifying_quaternion}
/// Extension of the standard [Quaternion] class, implementing the
/// [ChangeNotifier] functionality. This allows any interested party to be
/// notified when the value of this quaternion changes.
///
/// This class can be used as a regular [Quaternion] class. However, if you do
/// subscribe to notifications, don't forget to eventually unsubscribe in
/// order to avoid resource leaks.
///
/// Direct modification of this quaternion's [storage] is not allowed.
///
/// Every method of this quaternion that changes its value notifies (`negate`
/// through `conjugate`); writing the value it already has notifies nobody.
/// {@endtemplate}
class NotifyingQuaternion._() extends Quaternion with ChangeNotifier {
  /// {@macro notifying_quaternion}
  ///
  /// Constructs a quaternion using the raw values [x], [y], [z], and [w].
  factory NotifyingQuaternion(double x, double y, double z, double w) =>
      NotifyingQuaternion._()..setValues(x, y, z, w);
  this : super.fromFloat32List(Float32List(4));

  /// {@macro notifying_quaternion}
  ///
  /// Constructs a quaternion from a rotation matrix [rotationMatrix].
  factory NotifyingQuaternion.fromRotation(Matrix3 rotationMatrix) =>
      NotifyingQuaternion._()..setFromRotation(rotationMatrix);

  /// {@macro notifying_quaternion}
  ///
  /// Constructs a quaternion from a rotation of [angle] around [axis].
  factory NotifyingQuaternion.axisAngle(Vector3 axis, double angle) =>
      NotifyingQuaternion._()..setAxisAngle(axis, angle);

  /// {@macro notifying_quaternion}
  ///
  /// Constructs a quaternion as a copy of [other].
  factory NotifyingQuaternion.copy(Quaternion other) =>
      NotifyingQuaternion._()..setFrom(other);

  /// {@macro notifying_quaternion}
  ///
  /// Constructs a quaternion from time derivative of [q] with angular
  /// velocity [omega].
  factory NotifyingQuaternion.dq(Quaternion q, Vector3 omega) =>
      NotifyingQuaternion._()..setDQ(q, omega);

  /// {@macro notifying_quaternion}
  ///
  /// Constructs a quaternion from [yaw], [pitch] and [roll].
  factory NotifyingQuaternion.euler(double yaw, double pitch, double roll) =>
      NotifyingQuaternion._()..setEuler(yaw, pitch, roll);

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
  void setAxisAngle(Vector3 axis, double radians) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setAxisAngle(axis, radians);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setDQ(Quaternion q, Vector3 omega) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setDQ(q, omega);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setEuler(double yaw, double pitch, double roll) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setEuler(yaw, pitch, roll);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setFromRotation(Matrix3 rotationMatrix) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setFromRotation(rotationMatrix);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setFromTwoVectors(Vector3 a, Vector3 b) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setFromTwoVectors(a, b);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setRandom(Random rn) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setRandom(rn);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void setFrom(Quaternion source) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.setFrom(source);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void operator []=(int i, double arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super[i] = arg;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  double normalize() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    final l = super.normalize();
    _notifyIfChanged(x0, y0, z0, w0);
    return l;
  }

  @override
  void add(Quaternion arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.add(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void sub(Quaternion arg) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.sub(arg);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void scale(double scale) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.scale(scale);
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set x(double x) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.x = x;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set y(double y) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.y = y;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set z(double z) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.z = z;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  set w(double w) {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.w = w;
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void conjugate() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.conjugate();
    _notifyIfChanged(x0, y0, z0, w0);
  }

  @override
  void inverse() {
    final values = _values;
    final x0 = values[0];
    final y0 = values[1];
    final z0 = values[2];
    final w0 = values[3];
    super.inverse();
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
