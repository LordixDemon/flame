part of 'render_context_3d.dart';

class _JointUploadCache() {
  static const int _hashTableSize = 512;
  static const int _hashTableMask = _hashTableSize - 1;
  static const int _maxEntries = 256;

  List<Matrix4>? activeTransforms;

  Float32List _packScratch = Float32List(1024);
  late Uint8List _packBytes = _packScratch.buffer.asUint8List();
  int _packDirtyStart = 0;
  int _packDirtyEnd = 0;
  int _cacheFrame = -1;

  final List<_JointUploadEntry?> _hashTable = List.filled(
    _hashTableSize,
    null,
  );
  final Int32List _hashUsed = Int32List(_maxEntries);
  int _hashCount = 0;
  final List<_JointUploadEntry> _cachePool = [];

  void writeAndBind(
    GraphicsDevice device,
    _JointsEntry js,
    List<Matrix4> joints,
  ) {
    final count = joints.length;
    if (count > js.capacity) {
      throw StateError(
        'At most ${js.capacity} joints per surface are supported; '
        'found $count',
      );
    }
    final isRow = js.isRowMode;
    final stride = isRow ? 12 : 16;
    final base = isRow ? js.rowsOffset : js.jointsOffset;
    final floatLen = js.defaultBlock.data.length;
    final byteLen = floatLen * 4;

    final frame = device.frame;
    if (_cacheFrame != frame) {
      _cacheFrame = frame;
      final table = _hashTable;
      for (var k = 0; k < _hashCount; k++) {
        final slot = _hashUsed[k];
        final e = table[slot];
        if (e != null) {
          _cachePool.add(e);
          table[slot] = null;
        }
      }
      _hashCount = 0;
    }

    final hash = _hashJoints(joints, count, isRow, floatLen, base);
    final table = _hashTable;
    var slot = hash & _hashTableMask;
    while (true) {
      final e = table[slot];
      if (e == null) {
        break;
      }
      if (e.hash == hash &&
          e.isRow == isRow &&
          e.floatLen == floatLen &&
          e.jointCount == count &&
          e.base == base &&
          _jointsMatchSnapshot(e.snapshot, joints, count, isRow)) {
        RenderProfile.lap(RenderPhase.uniformWrite);
        device.bindUniformSlice(
          js.slot,
          e.buffer,
          offsetInBytes: e.offset,
          lengthInBytes: byteLen,
        );
        return;
      }
      slot = (slot + 1) & _hashTableMask;
    }

    if (_packScratch.length < floatLen) {
      _packScratch = Float32List(floatLen);
      _packBytes = _packScratch.buffer.asUint8List();
      _packDirtyStart = 0;
      _packDirtyEnd = 0;
    }
    final scratch = _packScratch;
    final writtenEnd = base + count * stride;
    if (_packDirtyEnd > _packDirtyStart) {
      if (_packDirtyStart < base) {
        final clearEnd = base < _packDirtyEnd ? base : _packDirtyEnd;
        if (clearEnd > _packDirtyStart) {
          scratch.fillRange(_packDirtyStart, clearEnd, 0.0);
        }
      }
      if (writtenEnd < _packDirtyEnd) {
        final clearStart = writtenEnd > _packDirtyStart
            ? writtenEnd
            : _packDirtyStart;
        if (_packDirtyEnd > clearStart) {
          scratch.fillRange(clearStart, _packDirtyEnd, 0.0);
        }
      }
    }
    _packDirtyStart = base;
    _packDirtyEnd = writtenEnd;

    if (isRow) {
      for (var i = 0; i < count; i++) {
        final m = joints[i].storage;
        final o = base + i * 12;
        scratch
          ..[o] = m[0]
          ..[o + 1] = m[4]
          ..[o + 2] = m[8]
          ..[o + 3] = m[12]
          ..[o + 4] = m[1]
          ..[o + 5] = m[5]
          ..[o + 6] = m[9]
          ..[o + 7] = m[13]
          ..[o + 8] = m[2]
          ..[o + 9] = m[6]
          ..[o + 10] = m[10]
          ..[o + 11] = m[14];
      }
    } else {
      for (var i = 0; i < count; i++) {
        scratch.setRange(base + i * 16, base + (i + 1) * 16, joints[i].storage);
      }
    }

    RenderProfile.lap(RenderPhase.uniformWrite);
    final buf = device.uploadUniformRange(_packBytes, byteLen);
    if (buf == null) {
      return;
    }
    final off = device.lastUploadedOffset;
    device.bindUniformSlice(
      js.slot,
      buf,
      offsetInBytes: off,
      lengthInBytes: byteLen,
    );
    if (_hashCount >= _maxEntries) {
      return;
    }
    final entry = _cachePool.isNotEmpty
        ? _cachePool.removeLast()
        : _JointUploadEntry();
    entry.store(
      hash: hash,
      isRow: isRow,
      floatLen: floatLen,
      jointCount: count,
      base: base,
      joints: joints,
      written: count * stride,
      buffer: buf,
      offset: off,
    );
    table[slot] = entry;
    _hashUsed[_hashCount++] = slot;
  }
}

class _JointUploadEntry() {
  int hash = 0;
  bool isRow = false;
  int floatLen = 0;
  int jointCount = 0;
  int base = 0;
  Float64List snapshot = Float64List(0);
  late GpuBuffer buffer;
  int offset = 0;

  void store({
    required int hash,
    required bool isRow,
    required int floatLen,
    required int jointCount,
    required int base,
    required List<Matrix4> joints,
    required int written,
    required GpuBuffer buffer,
    required int offset,
  }) {
    this.hash = hash;
    this.isRow = isRow;
    this.floatLen = floatLen;
    this.jointCount = jointCount;
    this.base = base;
    this.buffer = buffer;
    this.offset = offset;
    if (snapshot.length < written) {
      snapshot = Float64List(written);
    }
    if (isRow) {
      for (var i = 0; i < jointCount; i++) {
        final m = joints[i].storage;
        final o = i * 12;
        snapshot
          ..[o] = m[0]
          ..[o + 1] = m[4]
          ..[o + 2] = m[8]
          ..[o + 3] = m[12]
          ..[o + 4] = m[1]
          ..[o + 5] = m[5]
          ..[o + 6] = m[9]
          ..[o + 7] = m[13]
          ..[o + 8] = m[2]
          ..[o + 9] = m[6]
          ..[o + 10] = m[10]
          ..[o + 11] = m[14];
      }
    } else {
      for (var i = 0; i < jointCount; i++) {
        snapshot.setRange(i * 16, (i + 1) * 16, joints[i].storage);
      }
    }
  }
}

final Float32List _jointHashF32 = Float32List(18);
final Uint32List _jointHashU32 = _jointHashF32.buffer.asUint32List();

@pragma('vm:prefer-inline')
void _writeJointHashSample(List<Matrix4> joints, int index, int dstFloat) {
  final m = joints[index].storage;
  _jointHashF32
    ..[dstFloat] = m[0]
    ..[dstFloat + 1] = m[5]
    ..[dstFloat + 2] = m[10]
    ..[dstFloat + 3] = m[12]
    ..[dstFloat + 4] = m[13]
    ..[dstFloat + 5] = m[14];
}

int _hashJoints(
  List<Matrix4> joints,
  int count,
  bool isRow,
  int floatLen,
  int base,
) {
  var h = (isRow ? 1 : 0) ^ (floatLen * 31) ^ (count * 131) ^ (base * 1009);
  if (count <= 0) {
    return h & 0x1fffffff;
  }
  int floats;
  _writeJointHashSample(joints, 0, 0);
  if (count == 1) {
    floats = 6;
  } else if (count == 2) {
    _writeJointHashSample(joints, 1, 6);
    floats = 12;
  } else {
    _writeJointHashSample(joints, count >> 1, 6);
    _writeJointHashSample(joints, count - 1, 12);
    floats = 18;
  }
  final u32 = _jointHashU32;
  for (var k = 0; k < floats; k++) {
    final bits = u32[k];
    final norm = bits == 0x80000000 ? 0 : bits;
    h = 0x1fffffff & (h * 31 + norm);
  }
  return h;
}

bool _jointsMatchSnapshot(
  Float64List snapshot,
  List<Matrix4> joints,
  int count,
  bool isRow,
) {
  if (isRow) {
    for (var i = 0; i < count; i++) {
      final m = joints[i].storage;
      final o = i * 12;
      if (snapshot[o] != m[0] ||
          snapshot[o + 1] != m[4] ||
          snapshot[o + 2] != m[8] ||
          snapshot[o + 3] != m[12] ||
          snapshot[o + 4] != m[1] ||
          snapshot[o + 5] != m[5] ||
          snapshot[o + 6] != m[9] ||
          snapshot[o + 7] != m[13] ||
          snapshot[o + 8] != m[2] ||
          snapshot[o + 9] != m[6] ||
          snapshot[o + 10] != m[10] ||
          snapshot[o + 11] != m[14]) {
        return false;
      }
    }
    return true;
  }
  for (var i = 0; i < count; i++) {
    final m = joints[i].storage;
    final o = i * 16;
    for (var k = 0; k < 16; k++) {
      if (snapshot[o + k] != m[k]) {
        return false;
      }
    }
  }
  return true;
}
