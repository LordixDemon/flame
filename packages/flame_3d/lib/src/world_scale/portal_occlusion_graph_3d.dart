part of 'occlusion_culler_3d.dart';

/// Normalized 2D screen scissor rectangle `[minX, minY, maxX, maxY]` in
/// `[0, 1]` produced by [PortalOcclusionGraph3D].
class PortalScissorRect3D(
  final double minX,
  final double minY,
  final double maxX,
  final double maxY,
) {
  /// Whether this scissor has a positive non-empty area.
  bool get isValid => maxX > minX && maxY > minY;
}

/// An indoor room node in a [PortalOcclusionGraph3D].
class OcclusionRoom3D({
  /// Non-negative room identifier.
  required final int id,
  required Aabb3 bounds,

  /// Optional diagnostic label.
  final String? name,
}) {
  /// Creates an indoor visibility room with unique `id` and world `bounds`.
  this : assert(id >= 0, 'Room id must be non-negative');

  /// World-space bounding box of this room.
  final Aabb3 bounds = Aabb3.copy(bounds);
}

/// A convex doorway/window portal connecting [roomA] and [roomB] in a
/// [PortalOcclusionGraph3D].
class OcclusionPortal3D({
  /// First connected room id.
  required final int roomA,

  /// Second connected room id.
  required final int roomB,
  required List<Vector3> vertices,

  /// Whether this portal is open (`false` for closed doors/shutters).
  var bool isOpen = true,
}) {
  /// Creates a portal polygon with world-space `vertices` connecting `roomA`
  /// and `roomB`.
  this : assert(vertices.length >= 3, 'A portal needs at least 3 vertices') {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (final v in this.vertices) {
      minX = math.min(minX, v.x);
      minY = math.min(minY, v.y);
      minZ = math.min(minZ, v.z);
      maxX = math.max(maxX, v.x);
      maxY = math.max(maxY, v.y);
      maxZ = math.max(maxZ, v.z);
    }
    bounds = Aabb3.minMax(
      Vector3(minX - 0.15, minY - 0.15, minZ - 0.15),
      Vector3(maxX + 0.15, maxY + 0.15, maxZ + 0.15),
    );
  }

  /// World-space convex polygon corners of the portal opening.
  final List<Vector3> vertices = List.unmodifiable([
    for (final v in vertices) v.clone(),
  ]);

  /// Inflated world-space bounds used to detect when the camera stands inside
  /// the doorway itself.
  late final Aabb3 bounds;

  /// Convenience factory for an axis-aligned or wall-aligned rectangular door
  /// portal rising `+Y` by [height] from [bottomStart] to [bottomEnd].
  factory OcclusionPortal3D.rect({
    required int roomA,
    required int roomB,
    required Vector3 bottomStart,
    required Vector3 bottomEnd,
    required double height,
    bool isOpen = true,
  }) {
    return OcclusionPortal3D(
      roomA: roomA,
      roomB: roomB,
      vertices: [
        bottomStart,
        bottomEnd,
        Vector3(bottomEnd.x, bottomEnd.y + height, bottomEnd.z),
        Vector3(bottomStart.x, bottomStart.y + height, bottomStart.z),
      ],
      isOpen: isOpen,
    );
  }

  /// Returns the opposite room id across this portal from [roomId].
  int otherRoom(int roomId) => roomId == roomA ? roomB : roomA;
}

/// Recursive indoor portal-room visibility graph narrowing 2D normalized screen
/// scissor rectangles `[minX, minY, maxX, maxY]` across open portals in
/// `O(visible_portals)`.
class PortalOcclusionGraph3D() {
  final Map<int, OcclusionRoom3D> _rooms = <int, OcclusionRoom3D>{};
  final Map<int, List<OcclusionPortal3D>> _adjacency =
      <int, List<OcclusionPortal3D>>{};
  final List<OcclusionPortal3D> _portals = <OcclusionPortal3D>[];

  final Set<int> _visibleRooms = <int>{};
  final Set<int> _activeStack = <int>{};
  Float64List _roomScissors = Float64List(64);
  // The smallest portal depth at which each room was traversed with its
  // current scissor.
  Int32List _roomDepths = Int32List(16);
  final List<int> _startRooms = <int>[];
  final Float64List _rect = Float64List(4);
  int _maxRoomId = -1;
  int _traversedPortalCount = 0;

  final Float64List _clipA = Float64List(96);
  final Float64List _clipB = Float64List(96);

  /// Registered rooms by id.
  Iterable<OcclusionRoom3D> get rooms => _rooms.values;

  /// Registered portals.
  List<OcclusionPortal3D> get portals => List.unmodifiable(_portals);

  /// Room ids marked visible during the most recent [evaluateVisibility] call.
  Set<int> get visibleRoomIds => Set.unmodifiable(_visibleRooms);

  /// Number of open portal crossings evaluated in the last traversal.
  int get traversedPortalCount => _traversedPortalCount;

  /// Adds [room] to the visibility graph.
  void addRoom(OcclusionRoom3D room) {
    _rooms[room.id] = room;
    _adjacency.putIfAbsent(room.id, () => <OcclusionPortal3D>[]);
    if (room.id > _maxRoomId) {
      _maxRoomId = room.id;
      final needed = (_maxRoomId + 1) * 4;
      if (_roomScissors.length < needed) {
        _roomScissors = Float64List(math.max(needed, _roomScissors.length * 2));
      }
      if (_roomDepths.length <= _maxRoomId) {
        _roomDepths = Int32List(
          math.max(_maxRoomId + 1, _roomDepths.length * 2),
        );
      }
    }
  }

  /// Connects two rooms via [portal].
  void addPortal(OcclusionPortal3D portal) {
    _portals.add(portal);
    _adjacency
        .putIfAbsent(portal.roomA, () => <OcclusionPortal3D>[])
        .add(portal);
    _adjacency
        .putIfAbsent(portal.roomB, () => <OcclusionPortal3D>[])
        .add(portal);
  }

  /// Clears all rooms and portals.
  void clear() {
    _rooms.clear();
    _adjacency.clear();
    _portals.clear();
    _visibleRooms.clear();
    _activeStack.clear();
    _maxRoomId = -1;
    _traversedPortalCount = 0;
  }

  /// Evaluates room and portal visibility starting from [cameraRoomId] (or any
  /// room whose bounds contain [cameraPosition]).
  void evaluateVisibility({
    required Vector3 cameraPosition,
    required Matrix4 viewProjection,
    int? cameraRoomId,
    int maxPortalDepth = 16,
  }) {
    _visibleRooms.clear();
    _activeStack.clear();
    _traversedPortalCount = 0;

    final limit = (_maxRoomId + 1) * 4;
    for (var i = 0; i < limit; i += 4) {
      _roomScissors
        ..[i] = 1.0
        ..[i + 1] = 1.0
        ..[i + 2] = 0.0
        ..[i + 3] = 0.0;
    }

    if (_rooms.isEmpty) {
      return;
    }

    final startRooms = _startRooms..clear();
    if (cameraRoomId != null && _rooms.containsKey(cameraRoomId)) {
      startRooms.add(cameraRoomId);
    } else {
      for (final room in _rooms.values) {
        if (room.bounds.containsVector3(cameraPosition)) {
          startRooms.add(room.id);
        }
      }
    }

    if (startRooms.isEmpty) {
      // Camera is outdoors / outside all registered rooms: mark rooms whose
      // bounds project onscreen as visible roots.
      for (final room in _rooms.values) {
        if (_projectAabbNormalized(room.bounds, viewProjection, _rect)) {
          _enterRoom(
            room.id,
            _rect[0],
            _rect[1],
            _rect[2],
            _rect[3],
            cameraPosition,
            viewProjection,
            0,
            maxPortalDepth,
          );
        }
      }
      return;
    }

    for (final startId in startRooms) {
      _enterRoom(
        startId,
        0,
        0,
        1,
        1,
        cameraPosition,
        viewProjection,
        0,
        maxPortalDepth,
      );
    }
  }

  /// Whether [roomId] was reached through aligned open portals.
  bool isRoomVisible(int roomId) => _visibleRooms.contains(roomId);

  /// Returns the accumulated normalized `[0, 1]` screen scissor for [roomId],
  /// or `null` when [roomId] is culled.
  PortalScissorRect3D? roomScissor(int roomId) {
    if (!_visibleRooms.contains(roomId)) {
      return null;
    }
    final b = roomId * 4;
    return PortalScissorRect3D(
      _roomScissors[b],
      _roomScissors[b + 1],
      _roomScissors[b + 2],
      _roomScissors[b + 3],
    );
  }

  /// Tests whether [worldBounds] inside [roomId] is visible through [roomId]'s
  /// narrowed portal screen scissor.
  bool isAabbVisibleInRoom(
    int roomId,
    Aabb3 worldBounds,
    Matrix4 viewProjection,
  ) {
    if (!_visibleRooms.contains(roomId)) {
      return false;
    }
    final rect = _rect;
    if (!_projectAabbNormalized(worldBounds, viewProjection, rect)) {
      return false;
    }
    final b = roomId * 4;
    final sMinX = _roomScissors[b];
    final sMinY = _roomScissors[b + 1];
    final sMaxX = _roomScissors[b + 2];
    final sMaxY = _roomScissors[b + 3];
    return rect[2] > sMinX &&
        rect[0] < sMaxX &&
        rect[3] > sMinY &&
        rect[1] < sMaxY;
  }

  /// Adds the view `[minX, minY, maxX, maxY]` into [roomId] at portal
  /// [depth] and, when it shows more of the room than the views the room was
  /// already traversed with (or the room was only traversed deeper), follows
  /// its portals with the room's whole scissor.
  ///
  /// Following the union rather than the new view alone is what keeps the
  /// result independent of the order of the portals: a view contained in the
  /// union is skipped only because the union was followed already, and a
  /// downstream portal seen through any part of it was found then. The union
  /// may also cover wall between two views, so this errs on the side of
  /// reporting rooms visible.
  void _enterRoom(
    int roomId,
    double minX,
    double minY,
    double maxX,
    double maxY,
    Vector3 cameraPos,
    Matrix4 viewProjection,
    int depth,
    int maxDepth,
  ) {
    // `true` on the first visit too.
    final grew = _expandRoomScissor(roomId, minX, minY, maxX, maxY);
    if (!grew && depth >= _roomDepths[roomId]) {
      return;
    }
    _roomDepths[roomId] = depth;
    final b = roomId * 4;
    _traverse(
      roomId,
      _roomScissors[b],
      _roomScissors[b + 1],
      _roomScissors[b + 2],
      _roomScissors[b + 3],
      cameraPos,
      viewProjection,
      depth,
      maxDepth,
    );
  }

  void _traverse(
    int roomId,
    double sMinX,
    double sMinY,
    double sMaxX,
    double sMaxY,
    Vector3 cameraPos,
    Matrix4 viewProjection,
    int depth,
    int maxDepth,
  ) {
    if (depth >= maxDepth) {
      return;
    }
    final portals = _adjacency[roomId];
    if (portals == null || portals.isEmpty) {
      return;
    }

    _activeStack.add(roomId);
    for (var i = 0; i < portals.length; i++) {
      final portal = portals[i];
      if (!portal.isOpen) {
        continue;
      }
      final nextRoom = portal.otherRoom(roomId);
      if (!_rooms.containsKey(nextRoom) || _activeStack.contains(nextRoom)) {
        continue;
      }

      _traversedPortalCount++;
      double nMinX;
      double nMinY;
      double nMaxX;
      double nMaxY;

      if (portal.bounds.containsVector3(cameraPos)) {
        // Camera stands right in the doorway: pass current scissor unchanged.
        nMinX = sMinX;
        nMinY = sMinY;
        nMaxX = sMaxX;
        nMaxY = sMaxY;
      } else {
        final pRect = _rect;
        if (!_projectPortalNormalized(portal, viewProjection, pRect)) {
          continue;
        }
        nMinX = math.max(sMinX, pRect[0]);
        nMinY = math.max(sMinY, pRect[1]);
        nMaxX = math.min(sMaxX, pRect[2]);
        nMaxY = math.min(sMaxY, pRect[3]);
      }

      if (nMinX >= nMaxX || nMinY >= nMaxY) {
        continue;
      }

      _enterRoom(
        nextRoom,
        nMinX,
        nMinY,
        nMaxX,
        nMaxY,
        cameraPos,
        viewProjection,
        depth + 1,
        maxDepth,
      );
    }
    _activeStack.remove(roomId);
  }

  /// Unions `[minX, minY, maxX, maxY]` into [roomId]'s scissor and returns
  /// `true` if the room became newly visible or its scissor expanded.
  bool _expandRoomScissor(
    int roomId,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) {
    final b = roomId * 4;
    final wasVisible = _visibleRooms.add(roomId);
    if (wasVisible) {
      _roomScissors
        ..[b] = minX
        ..[b + 1] = minY
        ..[b + 2] = maxX
        ..[b + 3] = maxY;
      return true;
    }

    final curMinX = _roomScissors[b];
    final curMinY = _roomScissors[b + 1];
    final curMaxX = _roomScissors[b + 2];
    final curMaxY = _roomScissors[b + 3];
    if (minX >= curMinX - 1e-6 &&
        minY >= curMinY - 1e-6 &&
        maxX <= curMaxX + 1e-6 &&
        maxY <= curMaxY + 1e-6) {
      return false;
    }
    _roomScissors
      ..[b] = math.min(curMinX, minX)
      ..[b + 1] = math.min(curMinY, minY)
      ..[b + 2] = math.max(curMaxX, maxX)
      ..[b + 3] = math.max(curMaxY, maxY);
    return true;
  }

  bool _projectPortalNormalized(
    OcclusionPortal3D portal,
    Matrix4 viewProjection,
    Float64List out,
  ) {
    final verts = portal.vertices;
    final count = math.min(verts.length, 16);
    final vp = viewProjection.storage;

    for (var i = 0; i < count; i++) {
      final v = verts[i];
      final o = i * 4;
      _clipA
        ..[o] = vp[0] * v.x + vp[4] * v.y + vp[8] * v.z + vp[12]
        ..[o + 1] = vp[1] * v.x + vp[5] * v.y + vp[9] * v.z + vp[13]
        ..[o + 2] = vp[2] * v.x + vp[6] * v.y + vp[10] * v.z + vp[14]
        ..[o + 3] = vp[3] * v.x + vp[7] * v.y + vp[11] * v.z + vp[15];
    }

    final nW = clipPolygonW(_clipA, count, _clipB);
    if (nW < 3) {
      return false;
    }
    final nZ = clipPolygonNearZ(_clipB, nW, _clipA);
    if (nZ < 3) {
      return false;
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var minDepth = double.infinity;

    for (var i = 0; i < nZ; i++) {
      final o = i * 4;
      final invW = 1.0 / _clipA[o + 3];
      final sx = _clipA[o] * invW * 0.5 + 0.5;
      final sy = _clipA[o + 1] * invW * 0.5 + 0.5;
      final sz = _clipA[o + 2] * invW;
      minX = math.min(minX, sx);
      maxX = math.max(maxX, sx);
      minY = math.min(minY, sy);
      maxY = math.max(maxY, sy);
      minDepth = math.min(minDepth, sz);
    }

    if (minDepth > 1.0 || maxX <= 0.0 || minX >= 1.0 || maxY <= 0.0) {
      return false;
    }
    if (minY >= 1.0) {
      return false;
    }
    return _writeClampedRect(out, minX, minY, maxX, maxY);
  }

  static bool _writeClampedRect(
    Float64List out,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) {
    final cMinX = minX.clamp(0.0, 1.0);
    final cMinY = minY.clamp(0.0, 1.0);
    final cMaxX = maxX.clamp(0.0, 1.0);
    final cMaxY = maxY.clamp(0.0, 1.0);
    if (cMinX >= cMaxX || cMinY >= cMaxY) {
      return false;
    }
    out
      ..[0] = cMinX
      ..[1] = cMinY
      ..[2] = cMaxX
      ..[3] = cMaxY;
    return true;
  }

  static bool _projectAabbNormalized(
    Aabb3 box,
    Matrix4 viewProjection,
    Float64List out,
  ) {
    final vp = viewProjection.storage;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    var minZ = double.infinity;

    for (var c = 0; c < 8; c++) {
      final wx = (c & 1) == 0 ? box.min.x : box.max.x;
      final wy = (c & 2) == 0 ? box.min.y : box.max.y;
      final wz = (c & 4) == 0 ? box.min.z : box.max.z;
      final cx = vp[0] * wx + vp[4] * wy + vp[8] * wz + vp[12];
      final cy = vp[1] * wx + vp[5] * wy + vp[9] * wz + vp[13];
      final cz = vp[2] * wx + vp[6] * wy + vp[10] * wz + vp[14];
      final cw = vp[3] * wx + vp[7] * wy + vp[11] * wz + vp[15];
      if (cw <= 1e-5 || cz < 0) {
        return _writeClampedRect(out, 0, 0, 1, 1);
      }
      final invW = 1.0 / cw;
      final sx = cx * invW * 0.5 + 0.5;
      final sy = cy * invW * 0.5 + 0.5;
      final sz = cz * invW;
      minX = math.min(minX, sx);
      maxX = math.max(maxX, sx);
      minY = math.min(minY, sy);
      maxY = math.max(maxY, sy);
      minZ = math.min(minZ, sz);
      maxZ = math.max(maxZ, sz);
    }

    if (maxZ < 0 || minZ > 1 || maxX <= 0 || minX >= 1 || maxY <= 0) {
      return false;
    }
    if (minY >= 1) {
      return false;
    }
    return _writeClampedRect(out, minX, minY, maxX, maxY);
  }
}
