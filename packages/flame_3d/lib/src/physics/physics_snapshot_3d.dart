import 'dart:typed_data';

import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/core/crc32.dart';
import 'package:flame_3d/src/physics/physics_world_3d.dart'
    show WarmContactRecord3D;

/// Binary deterministic rollback snapshot codec for [PhysicsWorld3D] (with
/// `'P3DS'` magic header and IEEE 802.3 CRC32 integrity verification).
abstract final class PhysicsSnapshot3D._() {
  /// 4-byte ASCII magic `'P3DS'` (`0x50, 0x33, 0x44, 0x53`).
  static const int magicByte0 = 0x50; // 'P'

  /// Second magic byte `'3'`.
  static const int magicByte1 = 0x33; // '3'

  /// Third magic byte `'D'`.
  static const int magicByte2 = 0x44; // 'D'

  /// Fourth magic byte `'S'`.
  static const int magicByte3 = 0x53; // 'S'

  /// Current binary wire format version.
  ///
  /// Version `2` stores warm-start impulses per contact point by body index
  /// and feature id, so a snapshot restores into an identically built world.
  /// Version `1` snapshots are still read, without their warm-start entries.
  static const int formatVersion = 2;

  static const int _bodyRecordBytes = 168;
  static const int _warmRecordBytesV1 = 28;
  static const int _warmRecordBytes = 16 + 8 * WarmContactRecord3D.valueCount;
  static const int _wheelStateBytes = 49;

  /// Computes the IEEE 802.3 CRC32 checksum of `bytes[start..end)`.
  static int computeCrc32(Uint8List bytes, [int start = 0, int? end]) =>
      computeCrc32Bytes(bytes, start: start, end: end);

  /// Returns `true` when [bytes] has a valid `'P3DS'` header and matching
  /// trailing CRC32 checksum.
  static bool verifyChecksum(Uint8List bytes) {
    if (bytes.length < 60) {
      return false;
    }
    if (bytes[0] != magicByte0 ||
        bytes[1] != magicByte1 ||
        bytes[2] != magicByte2 ||
        bytes[3] != magicByte3) {
      return false;
    }
    final bd = ByteData.sublistView(bytes);
    final stored = bd.getUint32(bytes.length - 4, Endian.little);
    final actual = computeCrc32(bytes, 0, bytes.length - 4);
    return stored == actual;
  }

  /// Reads the simulation `tick` encoded in [bytes] after verifying magic and
  /// CRC32.
  static int peekTick(Uint8List bytes) {
    _validateHeaderAndCrc(bytes);
    final bd = ByteData.sublistView(bytes);
    final lo = bd.getUint32(8, Endian.little);
    final hi = bd.getUint32(12, Endian.little);
    return hi * 4294967296 + lo;
  }

  /// Encodes the complete simulation state of [world] (and optional [rng])
  /// into a compact binary [Uint8List] with `'P3DS'` magic and CRC32 footer.
  static Uint8List encodeWorld(PhysicsWorld3D world, {SeededRng3D? rng}) {
    final bodies = world.collectBodies();
    final warm = world.exportWarmStartRecords(bodies);
    final buoyancies = world.buoyancyVolumes;
    final vehicles = world.vehicles;

    var vehicleBytes = 4;
    for (var i = 0; i < vehicles.length; i++) {
      vehicleBytes += 28 + vehicles[i].wheelStates.length * _wheelStateBytes;
    }

    final rngBytes = rng != null ? 17 : 1;
    final totalBytes =
        16 + // magic(4) + version(2) + flags(2) + tick(8)
        8 + // accumulator
        24 + // gravity
        4 +
        buoyancies.length * 8 +
        vehicleBytes +
        4 +
        bodies.length * _bodyRecordBytes +
        4 +
        warm.length * _warmRecordBytes +
        rngBytes +
        4; // CRC32

    final out = Uint8List(totalBytes);
    final bd = ByteData.sublistView(out);
    var o = 0;

    // Header.
    out[0] = magicByte0;
    out[1] = magicByte1;
    out[2] = magicByte2;
    out[3] = magicByte3;
    o = 4;
    bd.setUint16(o, formatVersion, Endian.little);
    o += 2;
    bd.setUint16(o, 0, Endian.little);
    o += 2;

    final tick = world.tick;
    final tickLo = tick & 0xFFFFFFFF;
    final tickHi = (tick ~/ 4294967296) & 0xFFFFFFFF;
    bd.setUint32(o, tickLo, Endian.little);
    o += 4;
    bd.setUint32(o, tickHi, Endian.little);
    o += 4;

    // World accumulator & gravity.
    bd.setFloat64(o, world.accumulator, Endian.little);
    o += 8;
    bd.setFloat64(o, world.gravity.x, Endian.little);
    o += 8;
    bd.setFloat64(o, world.gravity.y, Endian.little);
    o += 8;
    bd.setFloat64(o, world.gravity.z, Endian.little);
    o += 8;

    // Buoyancy elapsed times.
    bd.setUint32(o, buoyancies.length, Endian.little);
    o += 4;
    for (var i = 0; i < buoyancies.length; i++) {
      bd.setFloat64(o, buoyancies[i].elapsedTime, Endian.little);
      o += 8;
    }

    // Vehicle states.
    bd.setUint32(o, vehicles.length, Endian.little);
    o += 4;
    for (var i = 0; i < vehicles.length; i++) {
      final v = vehicles[i];
      bd.setFloat64(o, v.throttle, Endian.little);
      o += 8;
      bd.setFloat64(o, v.steering, Endian.little);
      o += 8;
      bd.setFloat64(o, v.brake, Endian.little);
      o += 8;
      bd.setUint32(o, v.wheelStates.length, Endian.little);
      o += 4;
      for (var w = 0; w < v.wheelStates.length; w++) {
        final ws = v.wheelStates[w];
        bd.setUint8(o, ws.isGrounded ? 1 : 0);
        o += 1;
        bd.setFloat64(o, ws.suspensionLength, Endian.little);
        o += 8;
        bd.setFloat64(o, ws.compression, Endian.little);
        o += 8;
        bd.setFloat64(o, ws.suspensionImpulse, Endian.little);
        o += 8;
        bd.setFloat64(o, ws.skidInfo, Endian.little);
        o += 8;
        bd.setFloat64(o, ws.rotationRad, Endian.little);
        o += 8;
        bd.setFloat64(o, ws.steerAngleRad, Endian.little);
        o += 8;
      }
    }

    // RigidBody3D records (sorted by deterministicId).
    bd.setUint32(o, bodies.length, Endian.little);
    o += 4;
    for (var i = 0; i < bodies.length; i++) {
      final b = bodies[i];
      bd.setUint32(o, b.deterministicId, Endian.little);
      o += 4;
      bd.setUint8(o, b.bodyType.index);
      o += 1;
      final flags =
          (b.isSleeping ? 1 : 0) |
          (b.canSleep ? 2 : 0) |
          (b.ccdEnabled ? 4 : 0);
      bd.setUint8(o, flags);
      o += 1;
      bd.setUint16(o, 0, Endian.little);
      o += 2;

      final pos = b.bodyPosition;
      bd.setFloat64(o, pos.x, Endian.little);
      o += 8;
      bd.setFloat64(o, pos.y, Endian.little);
      o += 8;
      bd.setFloat64(o, pos.z, Endian.little);
      o += 8;

      final rot = b.bodyRotation;
      bd.setFloat64(o, rot.x, Endian.little);
      o += 8;
      bd.setFloat64(o, rot.y, Endian.little);
      o += 8;
      bd.setFloat64(o, rot.z, Endian.little);
      o += 8;
      bd.setFloat64(o, rot.w, Endian.little);
      o += 8;

      final lv = b.linearVelocity;
      bd.setFloat64(o, lv.x, Endian.little);
      o += 8;
      bd.setFloat64(o, lv.y, Endian.little);
      o += 8;
      bd.setFloat64(o, lv.z, Endian.little);
      o += 8;

      final av = b.angularVelocity;
      bd.setFloat64(o, av.x, Endian.little);
      o += 8;
      bd.setFloat64(o, av.y, Endian.little);
      o += 8;
      bd.setFloat64(o, av.z, Endian.little);
      o += 8;

      bd.setFloat64(o, b.sleepTimer, Endian.little);
      o += 8;

      final f = b.accumulatedForce;
      bd.setFloat64(o, f.x, Endian.little);
      o += 8;
      bd.setFloat64(o, f.y, Endian.little);
      o += 8;
      bd.setFloat64(o, f.z, Endian.little);
      o += 8;

      final tq = b.accumulatedTorque;
      bd.setFloat64(o, tq.x, Endian.little);
      o += 8;
      bd.setFloat64(o, tq.y, Endian.little);
      o += 8;
      bd.setFloat64(o, tq.z, Endian.little);
      o += 8;
    }

    // Warm-start contact impulses: body indices into the records above.
    bd.setUint32(o, warm.length, Endian.little);
    o += 4;
    for (var i = 0; i < warm.length; i++) {
      final r = warm[i];
      bd.setUint32(o, r.bodyA, Endian.little);
      o += 4;
      bd.setUint32(o, r.bodyB, Endian.little);
      o += 4;
      bd.setUint16(o, r.manifold, Endian.little);
      o += 2;
      bd.setUint16(o, 0, Endian.little);
      o += 2;
      bd.setInt32(o, r.featureId, Endian.little);
      o += 4;
      for (var k = 0; k < WarmContactRecord3D.valueCount; k++) {
        bd.setFloat64(o, r.values[k], Endian.little);
        o += 8;
      }
    }

    // Optional SeededRng3D state.
    if (rng != null) {
      bd.setUint8(o, 1);
      o += 1;
      final (s0, s1, s2, s3) = rng.saveState();
      bd.setUint32(o, s0, Endian.little);
      o += 4;
      bd.setUint32(o, s1, Endian.little);
      o += 4;
      bd.setUint32(o, s2, Endian.little);
      o += 4;
      bd.setUint32(o, s3, Endian.little);
      o += 4;
    } else {
      bd.setUint8(o, 0);
      o += 1;
    }

    // Trailing CRC32 checksum.
    final crc = computeCrc32(out, 0, o);
    bd.setUint32(o, crc, Endian.little);
    return out;
  }

  /// Decodes [bytes] (verifying `'P3DS'` magic and CRC32) and restores [world]
  /// (and optional [rng]) to the exact bit-identical state captured by
  /// [encodeWorld].
  ///
  /// Body records are matched to the world's bodies by creation id when the
  /// world holds every recorded body (the world the snapshot came from), by
  /// position in creation order when it holds none of them and as many bodies
  /// (an identically built world), and otherwise by creation id only:
  /// records of bodies that are gone are skipped and bodies added since keep
  /// their state. [matchByOrder] forces matching by position, for a world
  /// rebuilt in another process (creation ids restart with each process).
  static void restoreWorld(
    PhysicsWorld3D world,
    Uint8List bytes, {
    SeededRng3D? rng,
    bool matchByOrder = false,
  }) {
    _validateHeaderAndCrc(bytes);
    final bd = ByteData.sublistView(bytes);
    var o = 8;

    final tickLo = bd.getUint32(o, Endian.little);
    o += 4;
    final tickHi = bd.getUint32(o, Endian.little);
    o += 4;
    final tick = tickHi * 4294967296 + tickLo;

    final accumulator = bd.getFloat64(o, Endian.little);
    o += 8;
    final gx = bd.getFloat64(o, Endian.little);
    o += 8;
    final gy = bd.getFloat64(o, Endian.little);
    o += 8;
    final gz = bd.getFloat64(o, Endian.little);
    o += 8;
    world.gravity.setValues(gx, gy, gz);

    final buoyancyCount = bd.getUint32(o, Endian.little);
    o += 4;
    final buoyancies = world.buoyancyVolumes;
    for (var i = 0; i < buoyancyCount; i++) {
      final t = bd.getFloat64(o, Endian.little);
      o += 8;
      if (i < buoyancies.length) {
        buoyancies[i].elapsedTime = t;
      }
    }

    final vehicleCount = bd.getUint32(o, Endian.little);
    o += 4;
    final vehicles = world.vehicles;
    for (var i = 0; i < vehicleCount; i++) {
      final throttle = bd.getFloat64(o, Endian.little);
      o += 8;
      final steering = bd.getFloat64(o, Endian.little);
      o += 8;
      final brake = bd.getFloat64(o, Endian.little);
      o += 8;
      final wCount = bd.getUint32(o, Endian.little);
      o += 4;
      final v = i < vehicles.length ? vehicles[i] : null;
      if (v != null) {
        v.throttle = throttle;
        v.steering = steering;
        v.brake = brake;
      }
      for (var w = 0; w < wCount; w++) {
        final grounded = bd.getUint8(o) != 0;
        o += 1;
        final suspLen = bd.getFloat64(o, Endian.little);
        o += 8;
        final comp = bd.getFloat64(o, Endian.little);
        o += 8;
        final suspImp = bd.getFloat64(o, Endian.little);
        o += 8;
        final skid = bd.getFloat64(o, Endian.little);
        o += 8;
        final rotRad = bd.getFloat64(o, Endian.little);
        o += 8;
        final steerRad = bd.getFloat64(o, Endian.little);
        o += 8;
        if (v != null && w < v.wheelStates.length) {
          final ws = v.wheelStates[w];
          ws.isGrounded = grounded;
          ws.suspensionLength = suspLen;
          ws.compression = comp;
          ws.suspensionImpulse = suspImp;
          ws.skidInfo = skid;
          ws.rotationRad = rotRad;
          ws.steerAngleRad = steerRad;
        }
      }
    }

    final version = bd.getUint16(4, Endian.little);
    final bodies = world.collectBodies();
    final bodyById = <int, RigidBody3D>{
      for (final b in bodies) b.deterministicId: b,
    };

    final bodyCount = bd.getUint32(o, Endian.little);
    o += 4;
    final bodyStart = o;
    // Map records to bodies (see the dartdoc above).
    var knownIds = 0;
    for (var i = 0; i < bodyCount; i++) {
      final detId = bd.getUint32(
        bodyStart + i * _bodyRecordBytes,
        Endian.little,
      );
      if (bodyById.containsKey(detId)) {
        knownIds++;
      }
    }
    final byIndex =
        bodies.length == bodyCount && (matchByOrder || knownIds == 0);
    final recordBodies = List<RigidBody3D?>.filled(bodyCount, null);
    for (var i = 0; i < bodyCount; i++) {
      final detId = bd.getUint32(o, Endian.little);
      o += 4;
      final typeIdx = bd.getUint8(o);
      o += 1;
      final flags = bd.getUint8(o);
      o += 1;
      o += 2; // padding

      final px = bd.getFloat64(o, Endian.little);
      o += 8;
      final py = bd.getFloat64(o, Endian.little);
      o += 8;
      final pz = bd.getFloat64(o, Endian.little);
      o += 8;

      final qx = bd.getFloat64(o, Endian.little);
      o += 8;
      final qy = bd.getFloat64(o, Endian.little);
      o += 8;
      final qz = bd.getFloat64(o, Endian.little);
      o += 8;
      final qw = bd.getFloat64(o, Endian.little);
      o += 8;

      final lvx = bd.getFloat64(o, Endian.little);
      o += 8;
      final lvy = bd.getFloat64(o, Endian.little);
      o += 8;
      final lvz = bd.getFloat64(o, Endian.little);
      o += 8;

      final avx = bd.getFloat64(o, Endian.little);
      o += 8;
      final avy = bd.getFloat64(o, Endian.little);
      o += 8;
      final avz = bd.getFloat64(o, Endian.little);
      o += 8;

      final sleepTimer = bd.getFloat64(o, Endian.little);
      o += 8;

      final fx = bd.getFloat64(o, Endian.little);
      o += 8;
      final fy = bd.getFloat64(o, Endian.little);
      o += 8;
      final fz = bd.getFloat64(o, Endian.little);
      o += 8;

      final tx = bd.getFloat64(o, Endian.little);
      o += 8;
      final ty = bd.getFloat64(o, Endian.little);
      o += 8;
      final tz = bd.getFloat64(o, Endian.little);
      o += 8;

      final b = byIndex ? bodies[i] : bodyById[detId];
      recordBodies[i] = b;
      if (b != null) {
        if (typeIdx >= 0 && typeIdx < BodyType3D.values.length) {
          b.bodyType = BodyType3D.values[typeIdx];
        }
        b.canSleep = (flags & 2) != 0;
        b.ccdEnabled = (flags & 4) != 0;
        b.bodyPosition.setValues(px, py, pz);
        b.bodyRotation.setValues(qx, qy, qz, qw);
        b.linearVelocity.setValues(lvx, lvy, lvz);
        b.angularVelocity.setValues(avx, avy, avz);
        b.sleepTimer = sleepTimer;
        b.isSleeping = (flags & 1) != 0;
        b.accumulatedForce.setValues(fx, fy, fz);
        b.accumulatedTorque.setValues(tx, ty, tz);
        b.updateWorldInertia();
      }
    }

    final warmCount = bd.getUint32(o, Endian.little);
    o += 4;
    final warmRecords = <WarmContactRecord3D>[];
    if (version == 1) {
      // Version 1 keyed impulses by a hash of process-wide ids: unusable.
      o += warmCount * _warmRecordBytesV1;
    } else {
      for (var i = 0; i < warmCount; i++) {
        final bodyA = bd.getUint32(o, Endian.little);
        final bodyB = bd.getUint32(o + 4, Endian.little);
        final manifold = bd.getUint16(o + 8, Endian.little);
        final featureId = bd.getInt32(o + 12, Endian.little);
        final values = Float64List(WarmContactRecord3D.valueCount);
        for (var k = 0; k < values.length; k++) {
          values[k] = bd.getFloat64(o + 16 + k * 8, Endian.little);
        }
        warmRecords.add(
          WarmContactRecord3D(
            bodyA: bodyA,
            bodyB: bodyB,
            manifold: manifold,
            featureId: featureId,
            values: values,
          ),
        );
        o += _warmRecordBytes;
      }
    }

    final hasRng = bd.getUint8(o) != 0;
    o += 1;
    if (hasRng) {
      final s0 = bd.getUint32(o, Endian.little);
      o += 4;
      final s1 = bd.getUint32(o, Endian.little);
      o += 4;
      final s2 = bd.getUint32(o, Endian.little);
      o += 4;
      final s3 = bd.getUint32(o, Endian.little);
      o += 4;
      rng?.restoreState((s0, s1, s2, s3));
    }

    world.restoreInternalState(
      tick: tick,
      accumulator: accumulator,
      bodies: recordBodies,
      warmRecords: warmRecords,
    );
  }

  static void _validateHeaderAndCrc(Uint8List bytes) {
    if (bytes.length < 60) {
      throw const FormatException(
        'PhysicsSnapshot3D buffer is truncated (< 60 bytes).',
      );
    }
    if (bytes[0] != magicByte0 ||
        bytes[1] != magicByte1 ||
        bytes[2] != magicByte2 ||
        bytes[3] != magicByte3) {
      throw const FormatException(
        'Invalid PhysicsSnapshot3D magic header (expected "P3DS").',
      );
    }
    final bd = ByteData.sublistView(bytes);
    final version = bd.getUint16(4, Endian.little);
    if (version < 1 || version > formatVersion) {
      throw FormatException(
        'Unsupported PhysicsSnapshot3D version: $version '
        '(expected 1 to $formatVersion).',
      );
    }
    final expectedCrc = bd.getUint32(bytes.length - 4, Endian.little);
    final actualCrc = computeCrc32(bytes, 0, bytes.length - 4);
    if (expectedCrc != actualCrc) {
      throw FormatException(
        'PhysicsSnapshot3D CRC32 checksum mismatch '
        '(expected 0x${expectedCrc.toRadixString(16)}, '
        'computed 0x${actualCrc.toRadixString(16)}).',
      );
    }
  }
}

/// Fixed-capacity circular history buffer of binary [PhysicsSnapshot3D] frames
/// for low-latency rollback netcode and deterministic instant replays.
class PhysicsSnapshotRingBuffer3D({
  final int capacity = 120,
}) {
  this : assert(capacity >= 1, 'capacity must be >= 1') {
    _ticks = List<int>.filled(capacity, -1);
    _frames = List<Uint8List?>.filled(capacity, null);
  }

  late final List<int> _ticks;
  late final List<Uint8List?> _frames;
  int _head = 0; // Index of oldest valid slot when `_length > 0`.
  int _length = 0;

  /// Number of snapshots currently stored (`0 .. capacity`).
  int get length => _length;

  /// Whether no snapshots have been recorded yet.
  bool get isEmpty => _length == 0;

  /// Oldest tick currently retained in the ring buffer, or `null` if empty.
  int? get oldestTick => _length == 0 ? null : _ticks[_head];

  /// Most recent tick recorded in the ring buffer, or `null` if empty.
  int? get latestTick =>
      _length == 0 ? null : _ticks[(_head + _length - 1) % capacity];

  /// Clears all stored snapshots.
  void clear() {
    for (var i = 0; i < capacity; i++) {
      _ticks[i] = -1;
      _frames[i] = null;
    }
    _head = 0;
    _length = 0;
  }

  /// Captures a snapshot of [world] (and optional [rng]), appends it to the
  /// ring buffer, and returns the encoded bytes.
  Uint8List capture(PhysicsWorld3D world, {SeededRng3D? rng}) {
    final bytes = PhysicsSnapshot3D.encodeWorld(world, rng: rng);
    pushBytes(world.tick, bytes);
    return bytes;
  }

  /// Pushes an already-encoded snapshot [bytes] tagged with [tick].
  void pushBytes(int tick, Uint8List bytes) {
    if (_length < capacity) {
      final slot = (_head + _length) % capacity;
      _ticks[slot] = tick;
      _frames[slot] = bytes;
      _length++;
    } else {
      _ticks[_head] = tick;
      _frames[_head] = bytes;
      _head = (_head + 1) % capacity;
    }
  }

  /// Looks up the snapshot bytes recorded at exact [tick], or `null` if not in
  /// the window.
  Uint8List? snapshotForTick(int tick) {
    for (var i = _length - 1; i >= 0; i--) {
      final slot = (_head + i) % capacity;
      if (_ticks[slot] == tick) {
        return _frames[slot];
      }
    }
    return null;
  }

  /// Returns the snapshot recorded [framesAgo] entries back from the newest
  /// entry (`0` = latest), or `null` if out of range.
  Uint8List? snapshotFramesAgo(int framesAgo) {
    if (framesAgo < 0 || framesAgo >= _length) {
      return null;
    }
    final offset = _length - 1 - framesAgo;
    return _frames[(_head + offset) % capacity];
  }

  /// Rolls [world] back to the snapshot at [tick] and discards newer history
  /// entries after [tick]. Returns `true` if [tick] was found.
  bool rollbackToTick(
    PhysicsWorld3D world,
    int tick, {
    SeededRng3D? rng,
  }) {
    for (var i = _length - 1; i >= 0; i--) {
      final slot = (_head + i) % capacity;
      if (_ticks[slot] == tick) {
        final bytes = _frames[slot]!;
        PhysicsSnapshot3D.restoreWorld(world, bytes, rng: rng);
        // Trim newer entries `i + 1 .. _length - 1`.
        for (var j = i + 1; j < _length; j++) {
          final drop = (_head + j) % capacity;
          _ticks[drop] = -1;
          _frames[drop] = null;
        }
        _length = i + 1;
        return true;
      }
    }
    return false;
  }

  /// Rolls [world] back [framesAgo] entries from the newest entry (`0` =
  /// latest) and trims discarded future entries.
  bool rollbackFrames(
    PhysicsWorld3D world,
    int framesAgo, {
    SeededRng3D? rng,
  }) {
    if (framesAgo < 0 || framesAgo >= _length) {
      return false;
    }
    final targetIdx = _length - 1 - framesAgo;
    final slot = (_head + targetIdx) % capacity;
    return rollbackToTick(world, _ticks[slot], rng: rng);
  }
}
