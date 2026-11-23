part of 'transform_gizmo_3d.dart';

extension _TransformGizmoSolver on TransformGizmo3D {
  void _initDragForMode(GizmoAxis3D chosen, Vector3 ro, Vector3 rd) {
    switch (mode) {
      case GizmoMode3D.translate:
        if (_singleAxisVector(chosen) case final unitAxis?) {
          _dragStartAxisParam =
              closestRayAxisParam3D(
                _dragStartWorldOrigin,
                unitAxis,
                ro,
                rd,
                directionIsUnit: true,
                minDenom: 1e-6,
              ) ??
              0.0;
        } else {
          final normal = _planeNormalFor(chosen, rd);
          _dragPlaneNormal.setFrom(normal);
          final hit =
              _intersectPlane(ro, rd, _dragStartWorldOrigin, normal) ??
              _dragStartWorldOrigin;
          _dragStartPlanePoint.setFrom(hit);
        }

      case GizmoMode3D.rotate:
        final ringAxis = _singleAxisVector(chosen) ?? _dragAxisY;
        _dragRingAxis.setFrom(ringAxis);
        final denom = ringAxis.dot(rd);
        if (denom.abs() > 0.06) {
          _dragRingEdgeOn = false;
          final hit =
              _intersectPlane(ro, rd, _dragStartWorldOrigin, ringAxis) ??
              (_dragStartWorldOrigin + _perpendicularUnit(ringAxis));
          final radial = hit - _dragStartWorldOrigin;
          radial.sub(ringAxis * ringAxis.dot(radial));
          if (radial.length2 > 1e-10) {
            radial.normalize();
          } else {
            radial.setFrom(_perpendicularUnit(ringAxis));
          }
          _dragStartRingRadial.setFrom(radial);
        } else {
          _dragRingEdgeOn = true;
          _dragPlaneNormal.setFrom(-rd);
          final hit =
              _intersectPlane(
                ro,
                rd,
                _dragStartWorldOrigin,
                _dragPlaneNormal,
              ) ??
              _dragStartWorldOrigin;
          _dragStartPlanePoint.setFrom(hit);
          final tangent = ringAxis.cross(rd);
          if (tangent.length2 > 1e-10) {
            tangent.normalize();
          } else {
            tangent.setFrom(_perpendicularUnit(ringAxis));
          }
          _dragUniformDir.setFrom(tangent);
        }

      case GizmoMode3D.scale:
        if (_singleAxisVector(chosen) case final unitAxis?) {
          _dragStartAxisParam =
              closestRayAxisParam3D(
                _dragStartWorldOrigin,
                unitAxis,
                ro,
                rd,
                directionIsUnit: true,
                minDenom: 1e-6,
              ) ??
              0.0;
        } else {
          final normal = chosen == GizmoAxis3D.xyz
              ? -rd
              : _planeNormalFor(chosen, rd);
          _dragPlaneNormal.setFrom(normal);
          final hit =
              _intersectPlane(ro, rd, _dragStartWorldOrigin, normal) ??
              _dragStartWorldOrigin;
          _dragStartPlanePoint.setFrom(hit);
          if (chosen == GizmoAxis3D.xyz) {
            final upRef = rd.y.abs() < 0.9
                ? Vector3(0, 1, 0)
                : Vector3(1, 0, 0);
            final right = rd.cross(upRef)..normalize();
            final up = right.cross(rd)..normalize();
            _dragUniformDir
              ..setFrom(right + up)
              ..normalize();
          } else {
            final (u, v) = _planeAxesFor(chosen);
            _dragUniformDir
              ..setFrom(u + v)
              ..normalize();
          }
        }
    }
  }

  void _solveTranslate(Component3D activeTarget, Vector3 ro, Vector3 rd) {
    final worldOffset = Vector3.zero();
    final snap = translateSnap;

    if (_singleAxisVector(_activeAxis) case final unitAxis?) {
      final param = closestRayAxisParam3D(
        _dragStartWorldOrigin,
        unitAxis,
        ro,
        rd,
        directionIsUnit: true,
        minDenom: 1e-6,
      );
      if (param == null) {
        return;
      }
      var delta = param - _dragStartAxisParam;
      if (snap != null && snap > 0) {
        delta = (delta / snap).round() * snap;
      }
      worldOffset.setFrom(unitAxis * delta);
    } else if (_activeAxis == GizmoAxis3D.xyz) {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      worldOffset.setFrom(hit - _dragStartPlanePoint);
      if (snap != null && snap > 0) {
        worldOffset.setValues(
          (worldOffset.x / snap).round() * snap,
          (worldOffset.y / snap).round() * snap,
          (worldOffset.z / snap).round() * snap,
        );
      }
    } else {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      final rawDiff = hit - _dragStartPlanePoint;
      final (axisU, axisV) = _planeAxesFor(_activeAxis);
      var du = rawDiff.dot(axisU);
      var dv = rawDiff.dot(axisV);
      if (snap != null && snap > 0) {
        du = (du / snap).round() * snap;
        dv = (dv / snap).round() * snap;
      }
      worldOffset
        ..setFrom(axisU * du)
        ..add(axisV * dv);
    }

    final newWorldPos = _dragStartWorldOrigin + worldOffset;
    final newLocalPos = _dragParentInverse.transformed3(newWorldPos);
    activeTarget.position.setFrom(newLocalPos);
  }

  void _solveRotate(
    Component3D activeTarget,
    TransformSnapshot3D start,
    Vector3 ro,
    Vector3 rd,
  ) {
    double angle;
    if (!_dragRingEdgeOn) {
      final hit = _intersectPlane(ro, rd, _dragStartWorldOrigin, _dragRingAxis);
      if (hit == null) {
        return;
      }
      final radial = hit - _dragStartWorldOrigin;
      radial.sub(_dragRingAxis * _dragRingAxis.dot(radial));
      if (radial.length2 <= 1e-10) {
        return;
      }
      radial.normalize();
      final cross = _dragStartRingRadial.cross(radial);
      final sinAngle = _dragRingAxis.dot(cross);
      final cosAngle = _dragStartRingRadial.dot(radial).clamp(-1.0, 1.0);
      angle = math.atan2(sinAngle, cosAngle);
    } else {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      final delta = (hit - _dragStartPlanePoint).dot(_dragUniformDir);
      angle = delta / _dragGizmoScale;
    }

    final snap = rotateSnapRadians;
    if (snap != null && snap > 0) {
      angle = (angle / snap).round() * snap;
    }

    final worldDelta = Quaternion.axisAngle(_dragRingAxis, angle);
    final startWorldRot = _dragParentWorldRot * start.rotation;
    final nextWorldRot = worldDelta * startWorldRot;
    final nextLocalRot = (_dragParentWorldRotInv * nextWorldRot)..normalize();
    activeTarget.rotation.setFrom(nextLocalRot);
  }

  void _solveScale(
    Component3D activeTarget,
    TransformSnapshot3D start,
    Vector3 ro,
    Vector3 rd,
  ) {
    double delta;
    if (_singleAxisVector(_activeAxis) case final unitAxis?) {
      final param = closestRayAxisParam3D(
        _dragStartWorldOrigin,
        unitAxis,
        ro,
        rd,
        directionIsUnit: true,
        minDenom: 1e-6,
      );
      if (param == null) {
        return;
      }
      delta = param - _dragStartAxisParam;
    } else {
      final hit = _intersectPlane(
        ro,
        rd,
        _dragStartWorldOrigin,
        _dragPlaneNormal,
      );
      if (hit == null) {
        return;
      }
      delta = (hit - _dragStartPlanePoint).dot(_dragUniformDir);
    }

    final factor = math.max(0.01, 1.0 + delta / _dragGizmoScale);
    final next = start.scale.clone();
    switch (_activeAxis) {
      case GizmoAxis3D.x:
        next.x = _snapScaleValue(start.scale.x * factor);
      case GizmoAxis3D.y:
        next.y = _snapScaleValue(start.scale.y * factor);
      case GizmoAxis3D.z:
        next.z = _snapScaleValue(start.scale.z * factor);
      case GizmoAxis3D.xy:
        next.x = _snapScaleValue(start.scale.x * factor);
        next.y = _snapScaleValue(start.scale.y * factor);
      case GizmoAxis3D.xz:
        next.x = _snapScaleValue(start.scale.x * factor);
        next.z = _snapScaleValue(start.scale.z * factor);
      case GizmoAxis3D.yz:
        next.y = _snapScaleValue(start.scale.y * factor);
        next.z = _snapScaleValue(start.scale.z * factor);
      case GizmoAxis3D.xyz:
        next.setValues(
          _snapScaleValue(start.scale.x * factor),
          _snapScaleValue(start.scale.y * factor),
          _snapScaleValue(start.scale.z * factor),
        );
      case GizmoAxis3D.none:
        return;
    }
    activeTarget.scale.setFrom(next);
  }

  double _snapScaleValue(double raw) {
    final snap = scaleSnap;
    if (snap == null || snap <= 0) {
      return raw;
    }
    final snapped = (raw / snap).round() * snap;
    return raw >= 0 && snapped <= 0 ? snap : snapped;
  }

  Vector3? _singleAxisVector(GizmoAxis3D axis) {
    return switch (axis) {
      GizmoAxis3D.x => _dragAxisX,
      GizmoAxis3D.y => _dragAxisY,
      GizmoAxis3D.z => _dragAxisZ,
      _ => null,
    };
  }

  Vector3 _planeNormalFor(GizmoAxis3D axis, Vector3 rd) {
    return switch (axis) {
      GizmoAxis3D.xy => _dragAxisZ,
      GizmoAxis3D.xz => _dragAxisY,
      GizmoAxis3D.yz => _dragAxisX,
      _ => -rd,
    };
  }

  (Vector3, Vector3) _planeAxesFor(GizmoAxis3D axis) {
    return switch (axis) {
      GizmoAxis3D.xy => (_dragAxisX, _dragAxisY),
      GizmoAxis3D.xz => (_dragAxisX, _dragAxisZ),
      GizmoAxis3D.yz => (_dragAxisY, _dragAxisZ),
      _ => (_dragAxisX, _dragAxisY),
    };
  }
}
