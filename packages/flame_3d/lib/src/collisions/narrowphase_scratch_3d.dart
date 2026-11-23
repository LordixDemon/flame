part of 'collision_manifold_3d.dart';

class _DistanceScratch() {
  final Vector3 segA0 = Vector3.zero();
  final Vector3 segA1 = Vector3.zero();
  final Vector3 segB0 = Vector3.zero();
  final Vector3 segB1 = Vector3.zero();
  final Vector3 ptA = Vector3.zero();
  final Vector3 ptB = Vector3.zero();
  final Float64List segBreaks = Float64List(8);
  final Vector3 candSeg = Vector3.zero();
  final Vector3 candTri = Vector3.zero();
}

class _PrimitiveScratch() {
  final Vector3 boxNormal = Vector3.zero();
  final Vector3 boxNormalNeg = Vector3.zero();
  final _ObbFrame obbA = _ObbFrame();
  final _ObbFrame obbB = _ObbFrame();
  int satBestAxisCode = -1;
  double satMinPen = 0.0;
}

class _ClipScratch() {
  final _SupportFace3D faceA = _SupportFace3D();
  final _SupportFace3D faceB = _SupportFace3D();
  final _ClipBuffer3D clip = _ClipBuffer3D();
  final _ObbFrame obbFace = _ObbFrame();
  final Int32List chosen = Int32List(4);
  final Float32List f32Contact = Float32List(9);
  bool refIsA = false;
  double rnx = 0.0;
  double rny = 0.0;
  double rnz = 0.0;
  int base = 0;
  int pick = 0;
  int kept = 0;
}

class _GjkEpaScratch() {
  static const int maxEpaVerts = 64;
  static const int gjkTempSlot = 64;
  static final List<Vector3> seedDirs = _buildSphereDirs();

  final Float64List gjkP = Float64List((maxEpaVerts + 4) * 3);
  final Float64List gjkA = Float64List((maxEpaVerts + 4) * 3);
  final Float64List gjkB = Float64List((maxEpaVerts + 4) * 3);
  int gjkVertCount = 0;
  double gjkDx = 0.0;
  double gjkDy = 0.0;
  double gjkDz = 0.0;
  final Vector3 gjkDirVec = Vector3.zero();
  final Vector3 gjkNegDirVec = Vector3.zero();
  final Vector3 gjkSupA = Vector3.zero();
  final Vector3 gjkSupB = Vector3.zero();
  final Vector3 cA = Vector3.zero();
  final Vector3 cB = Vector3.zero();

  int epaFaceCap = 256;
  Int32List epaI0 = Int32List(256);
  Int32List epaI1 = Int32List(256);
  Int32List epaI2 = Int32List(256);
  Float64List epaFn = Float64List(256 * 3);
  Float64List epaFd = Float64List(256);
  Uint8List epaVisible = Uint8List(256);
  int epaFaceCount = 0;

  int epaHorizCap = 256;
  Int32List epaHorizA = Int32List(256);
  Int32List epaHorizB = Int32List(256);
  int epaHorizCount = 0;

  double epaNx = 0.0;
  double epaNy = 0.0;
  double epaNz = 0.0;
  double epaDepth = 0.0;
  double epaAx = 0.0;
  double epaAy = 0.0;
  double epaAz = 0.0;
  double epaBx = 0.0;
  double epaBy = 0.0;
  double epaBz = 0.0;

  void ensureEpaFaceCapacity(int count) {
    if (epaFaceCap >= count) {
      return;
    }
    final newCap = epaFaceCap * 2;
    epaI0 = Int32List(newCap)..setRange(0, epaFaceCount, epaI0);
    epaI1 = Int32List(newCap)..setRange(0, epaFaceCount, epaI1);
    epaI2 = Int32List(newCap)..setRange(0, epaFaceCount, epaI2);
    epaFn = Float64List(newCap * 3)..setRange(0, epaFaceCount * 3, epaFn);
    epaFd = Float64List(newCap)..setRange(0, epaFaceCount, epaFd);
    epaVisible = Uint8List(newCap);
    epaFaceCap = newCap;
  }

  void ensureEpaHorizonCapacity(int count) {
    if (epaHorizCap >= count) {
      return;
    }
    final newCap = epaHorizCap * 2;
    epaHorizA = Int32List(newCap)..setRange(0, epaHorizCount, epaHorizA);
    epaHorizB = Int32List(newCap)..setRange(0, epaHorizCount, epaHorizB);
    epaHorizCap = newCap;
  }
}

class _MeshTerrainScratch() {
  final MutableManifoldBuffer3D _rawManifoldBuf = MutableManifoldBuffer3D();
  bool _inRawManifoldBuf = false;

  MutableManifoldBuffer3D acquireRawBuffer() {
    if (_inRawManifoldBuf) {
      return MutableManifoldBuffer3D();
    }
    _inRawManifoldBuf = true;
    _rawManifoldBuf.clear();
    return _rawManifoldBuf;
  }

  void releaseRawBuffer(MutableManifoldBuffer3D buf) {
    if (identical(buf, _rawManifoldBuf)) {
      _inRawManifoldBuf = false;
    }
  }

  final List<Matrix4> cmpMatStack = [Matrix4.identity(), Matrix4.identity()];
  final List<Aabb3> cmpBoxStack = [Aabb3(), Aabb3()];
  final List<Aabb3> cmpOtherBoxStack = [Aabb3(), Aabb3()];

  Matrix4 borrowCmpMat(int depth) {
    while (cmpMatStack.length <= depth) {
      cmpMatStack.add(Matrix4.identity());
    }
    return cmpMatStack[depth];
  }

  Aabb3 borrowCmpBox(int depth) {
    while (cmpBoxStack.length <= depth) {
      cmpBoxStack.add(Aabb3());
    }
    return cmpBoxStack[depth];
  }

  Aabb3 borrowCmpOtherBox(int depth) {
    while (cmpOtherBoxStack.length <= depth) {
      cmpOtherBoxStack.add(Aabb3());
    }
    return cmpOtherBoxStack[depth];
  }

  final Matrix4 hfInvMat = Matrix4.identity();
  final Aabb3 hfWorldBox = Aabb3();
  final Aabb3 hfLocalBox = Aabb3();
  final Vector3 hfLv00 = Vector3.zero();
  final Vector3 hfLv01 = Vector3.zero();
  final Vector3 hfLv11 = Vector3.zero();
  final Vector3 hfLv10 = Vector3.zero();
  final Vector3 hfWv00 = Vector3.zero();
  final Vector3 hfWv01 = Vector3.zero();
  final Vector3 hfWv11 = Vector3.zero();
  final Vector3 hfWv10 = Vector3.zero();

  final Matrix4 invMesh = Matrix4.identity();
  final Aabb3 worldShapeBox = Aabb3();
  final Aabb3 localShapeBox = Aabb3();
  final List<int> candidateTris = [];
  final Vector3 triV0 = Vector3.zero();
  final Vector3 triV1 = Vector3.zero();
  final Vector3 triV2 = Vector3.zero();
  final Vector3 triCentroid = Vector3.zero();
}

class _ManifoldMergeScratch() {
  int groupCap = 64;
  Int32List repManifold = Int32List(64);
  Int32List groupHead = Int32List(64);
  Int32List manifoldNext = Int32List(64);
  Int32List manifoldGroup = Int32List(64);
  Int32List groupDeepest = Int32List(64);
  Int32List contactIdx = Int32List(256);

  void ensureGroupCap(int count) {
    if (groupCap >= count) {
      return;
    }
    var cap = groupCap;
    while (cap < count) {
      cap *= 2;
    }
    repManifold = Int32List(cap);
    groupHead = Int32List(cap);
    manifoldNext = Int32List(cap);
    manifoldGroup = Int32List(cap);
    groupDeepest = Int32List(cap);
    groupCap = cap;
  }

  void ensureContactCap(int count) {
    if (contactIdx.length >= count) {
      return;
    }
    var cap = contactIdx.length;
    while (cap < count) {
      cap *= 2;
    }
    contactIdx = Int32List(cap);
  }
}

class _NarrowphaseScratch() {
  final _DistanceScratch dist = _DistanceScratch();
  final _PrimitiveScratch prim = _PrimitiveScratch();
  final _ClipScratch clip = _ClipScratch();
  final _GjkEpaScratch gjk = _GjkEpaScratch();
  final _MeshTerrainScratch mesh = _MeshTerrainScratch();
  final _ManifoldMergeScratch merge = _ManifoldMergeScratch();
}
