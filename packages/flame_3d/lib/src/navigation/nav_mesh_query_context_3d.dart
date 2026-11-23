part of 'nav_mesh_3d.dart';

/// Reusable scratch state for [NavMesh3D] pathfinding and polygon queries.
///
/// Each [NavMesh3D] owns a default instance so normal queries allocate nothing;
/// callers running concurrent or re-entrant queries may supply independent
/// [NavQueryContext3D] instances to isolate A* and funnel scratch buffers.
class NavQueryContext3D() {
  /// Reusable candidate polygon indices populated during BVH queries.
  final List<int> bvhCandidates = [];

  Float64List? _gScore;
  Int32List? _cameFrom;
  Int32List? _cameViaLink;
  Int32List? _openStamp;
  Int32List? _closedStamp;
  _MinPolyHeap? _heap;
  int _searchStamp = 0;

  // Corridor string-pulling scratch buffers.
  final List<Vector3> portalLeft = [];
  final List<Vector3> portalRight = [];
  final List<int> portalLeftVertex = [];
  final List<int> portalRightVertex = [];
  final List<Vector3> cornerPoints = [];
  final List<int> cornerPortal = [];
  final List<int> cornerVertex = [];
  final List<int> cornerSide = [];

  void _ensureAStarCapacity(int polyCount) {
    if (_gScore == null || _gScore!.length < polyCount) {
      _gScore = Float64List(polyCount);
      _cameFrom = Int32List(polyCount);
      _cameViaLink = Int32List(polyCount);
      _openStamp = Int32List(polyCount);
      _closedStamp = Int32List(polyCount);
      _heap = _MinPolyHeap(polyCount);
      _searchStamp = 0;
    }
  }

  int _nextStamp(int polyCount) {
    if (_searchStamp >= 0x3FFFFFFF) {
      _openStamp!.fillRange(0, polyCount, 0);
      _closedStamp!.fillRange(0, polyCount, 0);
      _searchStamp = 0;
    }
    return ++_searchStamp;
  }
}
