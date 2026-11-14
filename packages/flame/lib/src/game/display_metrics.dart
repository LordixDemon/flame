import 'dart:ui';

import 'package:meta/meta.dart';

/// Snapshot of physical display characteristics for the `FlutterView` hosting a
/// `Game`.
@immutable
class const DisplayMetrics({
  required final double devicePixelRatio,
  required final Size physicalSize,
  required final double refreshRate,
}) {
  /// Logical size `(physicalSize / devicePixelRatio)`.
  Size get logicalSize => devicePixelRatio > 0
      ? Size(
          physicalSize.width / devicePixelRatio,
          physicalSize.height / devicePixelRatio,
        )
      : Size.zero;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DisplayMetrics &&
          (devicePixelRatio - other.devicePixelRatio).abs() < 1e-6 &&
          (physicalSize.width - other.physicalSize.width).abs() < 1e-3 &&
          (physicalSize.height - other.physicalSize.height).abs() < 1e-3 &&
          (refreshRate - other.refreshRate).abs() < 1e-3;

  @override
  int get hashCode => Object.hash(
    (devicePixelRatio * 1000).round(),
    physicalSize.width.round(),
    physicalSize.height.round(),
    (refreshRate * 10).round(),
  );

  @override
  String toString() =>
      'DisplayMetrics(dpr: $devicePixelRatio, '
      'physicalSize: $physicalSize, refreshRate: $refreshRate)';
}
