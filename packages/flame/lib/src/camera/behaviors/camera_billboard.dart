import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:vector_math/vector_math.dart';

/// Stabilizes a world-anchored [PositionComponent]'s rendered screen scale and
/// orientation against live `CameraComponent.viewfinder.zoom` and `angle`.
///
/// Ideal for floating damage/coin numbers, world price tags, 3D rooftop
/// callouts, and interactive map pins that belong to a world coordinate
/// `(x, y)` without becoming microscopic when zoomed out or gigantic when
/// zoomed in.
mixin CameraBillboard on PositionComponent {
  /// Whether billboard zoom/rotation compensation is active.
  bool billboardEnabled = true;

  /// Exponent in `[0.0 .. 1.0]` controlling how strongly camera zoom is
  /// counteracted (`1.0` keeps constant screen pixel size; `0.5` softens zoom
  /// changes halfway; `0.0` disables zoom compensation).
  double billboardZoomExponent = 1.0;

  /// Minimum world-space inverse scale factor applied around [position].
  double minBillboardScale = 0.35;

  /// Maximum world-space inverse scale factor applied around [position].
  double maxBillboardScale = 2.5;

  /// When `true`, counter-rotates by `-camera.viewfinder.angle` around
  /// [position] so labels always stay upright on screen.
  bool compensateCameraRotation = true;

  double _lastBillboardScale = 1.0;

  /// World-space inverse scale factor computed during the most recent render.
  double get lastBillboardScale => _lastBillboardScale;

  /// Computes the stabilized world-space scale multiplier for [cameraZoom].
  double computeBillboardScale(double cameraZoom) {
    if (!billboardEnabled || cameraZoom <= 1e-6 || billboardZoomExponent == 0) {
      return 1.0;
    }
    final raw = billboardZoomExponent == 1.0
        ? (1.0 / cameraZoom)
        : (1.0 / math.pow(cameraZoom, billboardZoomExponent).toDouble());
    return raw.clamp(minBillboardScale, maxBillboardScale);
  }

  @override
  void renderTree(Canvas canvas) {
    final camera = CameraComponent.currentCamera;
    if (!billboardEnabled || camera == null) {
      _lastBillboardScale = 1.0;
      super.renderTree(canvas);
      return;
    }
    final camZoom = camera.viewfinder.zoom;
    final camAngle = compensateCameraRotation ? camera.viewfinder.angle : 0.0;
    final invScale = computeBillboardScale(camZoom);
    _lastBillboardScale = invScale;

    if ((invScale - 1.0).abs() < 1e-5 && camAngle.abs() < 1e-5) {
      super.renderTree(canvas);
      return;
    }

    final px = position.x;
    final py = position.y;
    canvas.save();
    canvas.translate(px, py);
    if (camAngle.abs() >= 1e-5) {
      canvas.rotate(-camAngle);
    }
    if ((invScale - 1.0).abs() >= 1e-5) {
      canvas.scale(invScale, invScale);
    }
    canvas.translate(-px, -py);
    super.renderTree(canvas);
    canvas.restore();
  }
}

/// Keeps a world-space [PositionComponent] (such as a rooftop tooltip, hover
/// inspect card, or offscreen objective indicator) clamped inside the active
/// camera's visible world viewport inset by [viewportPinMargin].
mixin ViewportClampedPin on PositionComponent {
  /// Whether viewport clamping is active during rendering.
  bool viewportPinEnabled = true;

  /// Safe margin in logical viewport pixels from each edge of the camera view.
  EdgeInsets viewportPinMargin = const EdgeInsets.all(12);

  final Vector2 _lastClampDelta = Vector2.zero();

  /// World-space `(dx, dy)` translation applied on the most recent render pass
  /// to keep this component inside the camera's safe viewport bounds.
  Vector2 get lastClampDelta => _lastClampDelta;

  /// Computes the world-space `(dx, dy)` clamping offset needed to keep
  /// [targetWorldRect] inside [camera]'s `visibleWorldRect` inset by
  /// [viewportMargin] (expressed in viewport virtual pixels).
  static Offset computeClampOffset(
    Rect targetWorldRect,
    CameraComponent camera, {
    EdgeInsets viewportMargin = EdgeInsets.zero,
  }) {
    final visible = camera.visibleWorldRect;
    final invZoom = camera.viewfinder.zoom > 1e-6
        ? 1.0 / camera.viewfinder.zoom
        : 1.0;
    final minX = visible.left + viewportMargin.left * invZoom;
    final maxX = visible.right - viewportMargin.right * invZoom;
    final minY = visible.top + viewportMargin.top * invZoom;
    final maxY = visible.bottom - viewportMargin.bottom * invZoom;

    var dx = 0.0;
    var dy = 0.0;

    if (maxX > minX) {
      if (targetWorldRect.width >= (maxX - minX)) {
        dx = (minX + maxX) * 0.5 - targetWorldRect.center.dx;
      } else if (targetWorldRect.left < minX) {
        dx = minX - targetWorldRect.left;
      } else if (targetWorldRect.right > maxX) {
        dx = maxX - targetWorldRect.right;
      }
    }

    if (maxY > minY) {
      if (targetWorldRect.height >= (maxY - minY)) {
        dy = (minY + maxY) * 0.5 - targetWorldRect.center.dy;
      } else if (targetWorldRect.top < minY) {
        dy = minY - targetWorldRect.top;
      } else if (targetWorldRect.bottom > maxY) {
        dy = maxY - targetWorldRect.bottom;
      }
    }

    return Offset(dx, dy);
  }

  @override
  void renderTree(Canvas canvas) {
    final camera = CameraComponent.currentCamera;
    if (!viewportPinEnabled ||
        camera == null ||
        camera.parent == null ||
        size.x <= 0 ||
        size.y <= 0) {
      _lastClampDelta.setZero();
      super.renderTree(canvas);
      return;
    }

    var extraScale = 1.0;
    if (this is CameraBillboard) {
      extraScale = (this as CameraBillboard).computeBillboardScale(
        camera.viewfinder.zoom,
      );
    }
    final effW = size.x * scale.x.abs() * extraScale;
    final effH = size.y * scale.y.abs() * extraScale;
    final worldRect = Rect.fromLTWH(
      position.x - anchor.x * effW,
      position.y - anchor.y * effH,
      effW,
      effH,
    );

    final delta = computeClampOffset(
      worldRect,
      camera,
      viewportMargin: viewportPinMargin,
    );
    _lastClampDelta.setValues(delta.dx, delta.dy);
    if (delta.dx.abs() < 1e-4 && delta.dy.abs() < 1e-4) {
      super.renderTree(canvas);
      return;
    }

    canvas.save();
    canvas.translate(delta.dx, delta.dy);
    super.renderTree(canvas);
    canvas.restore();
  }
}
