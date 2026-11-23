part of 'crowd_steering_3d.dart';

extension _CrowdSteeringOrca3D on CrowdSteering3D {
  void _selectRvoVelocity2D({
    required int agentIndex,
    required int agentCount,
    required double prefU,
    required double prefV,
    required double maxOtherRadius,
    required double maxOtherSpeed,
    required bool useSpatialHash,
    required double rvoInvCell,
    required Vector2 outUV,
  }) {
    final me = agents[agentIndex];
    final myPosU = _posU[agentIndex];
    final myPosV = _posV[agentIndex];
    final myPosUp = _posUp[agentIndex];
    final myVelU = _velU[agentIndex];
    final myVelV = _velV[agentIndex];
    final myRadius = me.radius;
    final myMaxSpeed = me.maxSpeed;
    final myHorizon = me.timeHorizon;

    final prefSpeed = math.sqrt(prefU * prefU + prefV * prefV);
    final baseAngle = prefSpeed > 1e-5
        ? math.atan2(prefV, prefU)
        : (myVelU * myVelU + myVelV * myVelV > 1e-5
              ? math.atan2(myVelV, myVelU)
              : 0.0);
    final cosBase = math.cos(baseAngle);
    final sinBase = math.sin(baseAngle);
    final refSpeed = prefSpeed > 1e-4 ? prefSpeed : myMaxSpeed;

    // Collect relevant neighbors within agent i's RVO horizon ONCE outside
    // the 52-sample loop so inner collision checks never touch distant agents
    // or dereference `CrowdAgent3D`.
    var neighborCount = 0;
    final nbRelU = _nbRelU;
    final nbRelV = _nbRelV;
    final nbVelU = _nbVelU;
    final nbVelV = _nbVelV;
    final nbCombR2 = _nbCombR2;
    final nbMoving = _nbMoving;
    final searchR =
        myRadius +
        maxOtherRadius +
        safetyMargin +
        (myMaxSpeed + maxOtherSpeed) * myHorizon;

    var useGrid = false;
    var minCu = 0;
    var maxCu = 0;
    var minCv = 0;
    var maxCv = 0;
    if (useSpatialHash) {
      minCu = ((myPosU - searchR) * rvoInvCell).floor();
      maxCu = ((myPosU + searchR) * rvoInvCell).floor();
      minCv = ((myPosV - searchR) * rvoInvCell).floor();
      maxCv = ((myPosV + searchR) * rvoInvCell).floor();
      if ((maxCu - minCu + 1) * (maxCv - minCv + 1) < agentCount) {
        useGrid = true;
      }
    }

    if (useGrid) {
      final mask = _hashMask;
      for (var cv = minCv; cv <= maxCv; cv++) {
        for (var cu = minCu; cu <= maxCu; cu++) {
          final bucket = ((cu * 73856093) ^ (cv * 19349663)) & mask;
          var j = _gridHeads[bucket];
          while (j != -1) {
            if (j != agentIndex &&
                _agentCellU[j] == cu &&
                _agentCellV[j] == cv &&
                (_posUp[j] - myPosUp).abs() <= 1.5) {
              final relU = _posU[j] - myPosU;
              final relV = _posV[j] - myPosV;
              final combinedR = myRadius + _agentRadius[j] + safetyMargin;
              final maxD =
                  combinedR + (myMaxSpeed + _agentMaxSpeed[j]) * myHorizon;
              if (relU * relU + relV * relV <= maxD * maxD) {
                nbRelU[neighborCount] = relU;
                nbRelV[neighborCount] = relV;
                nbVelU[neighborCount] = _velU[j];
                nbVelV[neighborCount] = _velV[j];
                nbCombR2[neighborCount] = combinedR * combinedR;
                nbMoving[neighborCount] = _agentMoving[j];
                neighborCount++;
              }
            }
            j = _gridNext[j];
          }
        }
      }
    } else {
      for (var j = 0; j < agentCount; j++) {
        if (j == agentIndex) {
          continue;
        }
        if ((_posUp[j] - myPosUp).abs() > 1.5) {
          continue;
        }
        final relU = _posU[j] - myPosU;
        final relV = _posV[j] - myPosV;
        final combinedR = myRadius + _agentRadius[j] + safetyMargin;
        final maxD = combinedR + (myMaxSpeed + _agentMaxSpeed[j]) * myHorizon;
        if (relU * relU + relV * relV <= maxD * maxD) {
          nbRelU[neighborCount] = relU;
          nbRelV[neighborCount] = relV;
          nbVelU[neighborCount] = _velU[j];
          nbVelV[neighborCount] = _velV[j];
          nbCombR2[neighborCount] = combinedR * combinedR;
          nbMoving[neighborCount] = _agentMoving[j];
          neighborCount++;
        }
      }
    }

    var bestU = prefU;
    var bestV = prefV;
    var bestPenalty = double.infinity;
    final sepScale = me.separationWeight * myMaxSpeed * myHorizon;
    final leftBias = 0.03 * myMaxSpeed;

    // Candidate angles (in radians) and speed scales around `baseAngle`.
    for (var si = 0; si < _CrowdSteeringScratch.speedScales.length; si++) {
      final speedScale = _CrowdSteeringScratch.speedScales[si];
      final spd = speedScale == 0.0 ? 0.0 : refSpeed * speedScale;
      for (
        var ai = 0;
        ai < _CrowdSteeringScratch._candidateAngles.length;
        ai++
      ) {
        if (spd == 0.0 && ai > 0) {
          break;
        }
        final offset = _CrowdSteeringScratch._candidateAngles[ai];
        final cosAng =
            cosBase * _CrowdSteeringScratch.cosOffsets[ai] -
            sinBase * _CrowdSteeringScratch.sinOffsets[ai];
        final sinAng =
            sinBase * _CrowdSteeringScratch.cosOffsets[ai] +
            cosBase * _CrowdSteeringScratch.sinOffsets[ai];
        final cu = spd * cosAng;
        final cv = spd * sinAng;

        final du = cu - prefU;
        final dv = cv - prefV;
        var penalty = math.sqrt(du * du + dv * dv);
        // Right-hand rule tie-breaker (`offset < 0` is right turn in `(U, V)`).
        if (offset > 1e-4) {
          penalty += leftBias;
        }
        if (penalty >= bestPenalty) {
          continue;
        }

        var minTtc = double.infinity;
        for (var k = 0; k < neighborCount; k++) {
          final otherVelU = nbVelU[k];
          final otherVelV = nbVelV[k];
          final otherMoving = nbMoving[k] != 0;
          final rvoVx = otherMoving
              ? (2.0 * cu - myVelU - otherVelU)
              : (cu - otherVelU);
          final rvoVy = otherMoving
              ? (2.0 * cv - myVelV - otherVelV)
              : (cv - otherVelV);

          final ttc = _timeToCollision2DSq(
            nbRelU[k],
            nbRelV[k],
            rvoVx,
            rvoVy,
            nbCombR2[k],
          );
          if (ttc < minTtc) {
            minTtc = ttc;
            if (minTtc <= 0.02) {
              break;
            }
          }
        }

        if (minTtc < myHorizon) {
          penalty += sepScale / math.max(0.02, minTtc);
        }

        if (penalty < bestPenalty) {
          bestPenalty = penalty;
          bestU = cu;
          bestV = cv;
        }
      }
    }

    outUV.setValues(bestU, bestV);
  }

  static double _timeToCollision2DSq(
    double px,
    double py,
    double vx,
    double vy,
    double r2,
  ) {
    // Ray `0 + t * v` intersecting disk centered at `p` of radius `r`:
    // `||t * v - p||^2 = r^2`.
    final c = px * px + py * py - r2;
    if (c <= 0.0) {
      // Already inside combined margin: strongly penalize moving closer
      // (`v . p > 0`), allow separating (`v . p < 0`).
      final vp = vx * px + vy * py;
      return vp >= 0.0 ? 0.01 : 0.35;
    }
    final a = vx * vx + vy * vy;
    if (a <= 1e-10) {
      return double.infinity;
    }
    final b = -(vx * px + vy * py); // half-b in `a*t^2 + 2*b*t + c = 0`
    if (b >= 0.0) {
      return double.infinity;
    }
    final disc = b * b - a * c;
    if (disc < 0.0) {
      return double.infinity;
    }
    final t = (-b - math.sqrt(disc)) / a;
    return t >= 0.0 ? t : double.infinity;
  }

  void _ensureScratchCapacity(int count) {
    if (_posU.length < count) {
      var cap = math.max(32, _posU.length);
      while (cap < count) {
        cap *= 2;
      }
      _posU = Float64List(cap);
      _posV = Float64List(cap);
      _posUp = Float64List(cap);
      _velU = Float64List(cap);
      _velV = Float64List(cap);
      _prefU = Float64List(cap);
      _prefV = Float64List(cap);
      _prefUp = Float64List(cap);
      _agentRadius = Float64List(cap);
      _agentMaxSpeed = Float64List(cap);
      _agentMoving = Uint8List(cap);
      _nbRelU = Float64List(cap);
      _nbRelV = Float64List(cap);
      _nbVelU = Float64List(cap);
      _nbVelV = Float64List(cap);
      _nbCombR2 = Float64List(cap);
      _nbMoving = Uint8List(cap);
      _agentCellU = Int32List(cap);
      _agentCellV = Int32List(cap);
      _gridNext = Int32List(cap);
    }
    final targetHash = count * 4;
    if (_gridHeads.length < targetHash) {
      var h = math.max(64, _gridHeads.length);
      while (h < targetHash) {
        h *= 2;
      }
      _gridHeads = Int32List(h);
      _hashMask = h - 1;
    }
  }

  void _rebuildSpatialHash(int count, double invCellSize) {
    _gridHeads.fillRange(0, _gridHeads.length, -1);
    final mask = _hashMask;
    for (var i = 0; i < count; i++) {
      final cu = (_posU[i] * invCellSize).floor();
      final cv = (_posV[i] * invCellSize).floor();
      _agentCellU[i] = cu;
      _agentCellV[i] = cv;
      final bucket = ((cu * 73856093) ^ (cv * 19349663)) & mask;
      _gridNext[i] = _gridHeads[bucket];
      _gridHeads[bucket] = i;
    }
  }
}

class _CrowdSteeringScratch() {
  final Vector3 prefVel = Vector3.zero();
  final Vector2 chosenUV = Vector2.zero();
  final Vector3 basisU = Vector3.zero();
  final Vector3 basisV = Vector3.zero();

  static const List<double> speedScales = [1.0, 0.75, 0.45, 0.0];
  static const List<double> _candidateAngles = [
    0.0,
    -0.2617993877991494, // -15 deg (right)
    0.2617993877991494, // +15 deg (left)
    -0.5235987755982988, // -30 deg
    0.5235987755982988, // +30 deg
    -0.7853981633974483, // -45 deg
    0.7853981633974483, // +45 deg
    -1.0471975511965976, // -60 deg
    1.0471975511965976, // +60 deg
    -1.3962634015954636, // -80 deg
    1.3962634015954636, // +80 deg
    -1.8325957145940461, // -105 deg
    1.8325957145940461, // +105 deg
  ];
  static final Float64List cosOffsets = Float64List.fromList([
    for (final a in _CrowdSteeringScratch._candidateAngles) math.cos(a),
  ]);
  static final Float64List sinOffsets = Float64List.fromList([
    for (final a in _CrowdSteeringScratch._candidateAngles) math.sin(a),
  ]);
}
