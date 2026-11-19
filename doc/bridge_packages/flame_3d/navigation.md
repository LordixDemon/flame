# Navigation

`package:flame_3d/navigation.dart` finds paths for characters over the walkable surfaces of a 3D
level. It has three parts:

- `NavMeshBuilder3D` turns level geometry into a navigation mesh: it voxelizes the triangles,
  keeps the floor a character fits on and stays away from walls by the character's radius;
- `NavMesh3D` is the navigation mesh itself, a set of walkable triangles connected through their
  shared edges. It answers path, nearest-point and height queries, and takes dynamic obstacles,
  off-mesh links (jumps, ladders) and per-triangle costs;
- `CrowdSteering3D` moves a group of `CrowdAgent3D`s along their paths while they avoid each
  other.

Everything is CPU work in plain Dart, with no GPU involvement, so it runs on every platform the
package runs on, in `flutter test` and in a background isolate. Nothing here is a `Component`:
build the mesh when a level loads, and call the queries and `CrowdSteering3D.update` from your own
components.


## Building a navigation mesh


### From level geometry

`NavMeshBuilder3D.fromGeometry` takes the triangles of the level, the floors as well as the walls,
furniture and ceilings that limit where a character can go, and returns a `NavMesh3D`:

```dart
final navMesh = NavMeshBuilder3D.fromMeshes(
  [
    (groundMesh, null),
    (houseMesh, Matrix4.translationValues(4, 0, -2)),
  ],
  config: const NavMeshBuildConfig3D(agentRadius: 0.4),
);

final path = navMesh.findPath(Vector3(-8, 0, -8), Vector3(6, 0, 5));
```

`fromMeshes` takes `(Mesh, Matrix4?)` pairs and reads the positions and indices of every surface
of each mesh. `fromGeometry` takes the same data as raw `NavMeshGeometrySource3D`s, for geometry
that is not a `Mesh` (collision meshes, a level format of your own):

```dart
final source = NavMeshGeometrySource3D(
  positions: Float32List.fromList([
    -10, 0, -10, //
    10, 0, -10,
    10, 0, 10,
    -10, 0, 10,
  ]),
  indices: const [0, 3, 2, 0, 2, 1],
  transform: Matrix4.identity(), // optional, applied to the positions
);
final floorMesh = NavMeshBuilder3D.fromGeometry([source]);
```

`positions` holds `x, y, z` per vertex and `indices` three vertex indices per triangle. Triangles
with an index out of range or no area are skipped. A transform with a negative determinant (a
mirror) is handled.

The builder runs these steps, the first steps of the Recast pipeline:

1. Every triangle is classified as walkable when the angle between its normal and +Y is at most
   `maxSlopeDeg`. The normal follows the winding: a floor must be counter-clockwise seen from
   above, as the meshes of the package (`PlaneMesh`, `CuboidMesh`) are. A floor wound the other
   way faces down and is not walkable.
2. The triangles are rasterized into columns of `cellSize` by `cellSize` on the XZ plane, each
   column a list of solid spans in steps of `cellHeight`. Touching or overlapping spans merge, and
   a span is walkable when its top comes from a walkable triangle.
3. A walkable span is kept when the next solid span above it leaves at least `agentHeight` of
   headroom: the floor under a low table or a low ceiling is dropped, the top of the table stays.
4. Spans in neighboring columns (four directions) connect when their heights differ by at most
   `maxClimb` and they share `agentHeight` of headroom. This is what makes stairs walkable and
   cliffs not.
5. A two-pass distance transform measures how far each span is from the edge of the walkable area
   (a wall, a ledge, a cliff or the border of the input), and spans closer than `agentRadius` are
   removed. Gaps narrower than about twice the radius close.
6. Every remaining span becomes one square of two triangles at its height. Where neighboring
   squares meet, corners whose heights are within `maxClimb` merge into one vertex at their mean
   height: squares that connect share edges and form one mesh, and squares on either side of a
   cliff stay apart.

The result has no region partitioning, contour tracing or polygon simplification: it is a grid of
`cellSize` squares, two triangles per cell. A 10 by 10 m floor at the default settings gives
2,888 triangles; a 60 by 60 m one gives about 110,000. Searches and memory grow with that count,
see [Costs](#costs), so pick `cellSize` as coarse as the narrowest passage allows. Paths are
straight on such grids all the same, see [Paths](#paths).

The builder works with +Y up only. For a scene with another up axis, see
[Scenes with Z up](#scenes-with-z-up).


### Build settings

`NavMeshBuildConfig3D` holds the settings, in world units (meters when 1 unit is 1 m):

| Setting       | Default | Meaning                                                          |
|---------------|---------|------------------------------------------------------------------|
| `cellSize`    | `0.25`  | Width of a voxel column on X and Z, and the size of the squares. |
| `cellHeight`  | `0.15`  | Height of a voxel step.                                          |
| `agentHeight` | `1.8`   | Headroom a character needs above the floor.                      |
| `agentRadius` | `0.35`  | Distance kept from walls and ledges; `0` keeps the edge spans.   |
| `maxClimb`    | `0.45`  | Largest height step between neighboring cells that connects.     |
| `maxSlopeDeg` | `45`    | Steepest walkable triangle, in degrees, in `[0, 90)`.            |

The values are checked by asserts only. Use one mesh per character size: a mesh built for a small
radius lets a large character brush against walls, and one built for a large radius closes doors
to small ones.


### From walkable triangles

`NavMesh3D.fromMesh` uses the triangles of a mesh directly, without voxels: every triangle whose
normal is within `maxSlopeAngleRad` (default `0.8`, about 46 degrees) of `upAxis` (default +Y)
becomes a polygon, and vertices closer than `weldEpsilon` (default `0.001`) are welded so that
triangles sharing an edge connect:

```dart
final walkMesh = NavMesh3D.fromMesh(
  walkableAreaMesh,
  transform: Matrix4.translationValues(20, 0, 0), // where the mesh is placed
);
```

Use it with a mesh made for navigation, such as a hand-made walk mesh or a terrain: it does not
look at walls or ceilings and does not keep any distance from edges, so paths run along the very
border of the triangles. Its polygons are as large as the input triangles, which keeps searches
fast, but a dynamic obstacle blocks whole triangles (see
[Dynamic obstacles](#dynamic-obstacles)).

`NavMesh3D.fromIndexedTriangles` builds a mesh from welded vertices and
`(i0, i1, i2, normal)` records, for triangles that come from your own tools.


### Building in the background

The builder is pure Dart and its result can be sent between isolates, so a large level can be
built without blocking the game loop:

```dart
Future<NavMesh3D> buildInBackground(
  List<NavMeshGeometrySource3D> sources,
) {
  return Isolate.run(() => NavMeshBuilder3D.fromGeometry(sources));
}
```


## Queries


### Nearest point

`findNearestPoly` returns the point of the mesh closest to a point, with its polygon and squared
distance, or `null` for an empty mesh. Blocked polygons are skipped unless
`ignoreObstacles: true`. It walks a bounding volume hierarchy built on the first query, so it
takes microseconds even on large meshes:

```dart
final hit = navMesh.findNearestPoly(clickedPoint);
if (hit != null && hit.distanceSquared < 0.25) {
  moveTo(hit.point);
}
```

There is no distance limit: a point far from the mesh still gets the closest polygon, so check
`distanceSquared` when that matters.


### Paths

`findPath(start, goal)` snaps both points to the mesh with `findNearestPoly`, searches the
polygons with A* and returns the path as a list of points, from the snapped start to the snapped
goal. It returns an empty list when the goal cannot be reached.

When the straight line from the start to the goal stays on the mesh, over polygons of the lowest
cost, and the mesh has no off-mesh links, that line is the path and no search runs. Otherwise A*
searches the polygons, the cost of a step being the distance between their centroids times the
mean cost of the two polygons (see [Area costs](#area-costs)), and the corridor of polygons it
finds is straightened with the funnel algorithm (string pulling):

1. The corridor is first widened along lines of sight: from the start, the farthest corner of the
   path that a straight walk over the mesh reaches becomes the next anchor, and the polygons along
   that line replace the corridor's polygons up to it.
2. A shortest path bends only at corners of the walkable area. Wherever the funnel's path still
   bends at a vertex that has walkable polygons all around it (a staircase in the corridor, typical
   of grids and terrains), the corridor is moved to the other side of that vertex, which shortens
   the path, until no such bend remains.

In both steps the corridor takes no blocked polygon and no polygon more expensive than those it
replaces, so paths still go around the regions that the search avoided because of their cost.
Waypoints the path goes straight through are left out. Where a straight leg crosses polygons at
other heights (over a ridge, down a slope), points are inserted at the crossed edges so the path
follows the surface instead of cutting through it.

```dart
// Across an empty 20 m floor from the builder: two points, 22.6 m.
final straight = navMesh.findPath(Vector3(-8, 0, 8), Vector3(8, 0, -8));
```

The path is the shortest one through the sequence of open regions the search picked; around a
group of obstacles, A* can pick a way that is not the shortest one, and the funnel keeps it.

The other path queries:

- `findSegmentedPath` returns the same path cut into `NavPathSegment3D`s: walking legs, and one
  segment for each off-mesh link taken, with its `offMeshLink` and `linkTag`, so a character can
  switch to a jump or climb animation (see [Off-mesh links](#off-mesh-links)).
- `findCentroidPath` returns the raw corridor, the polygon centroids between the two snapped
  points, which is useful to see what the search did.

The path goes through the corners of the mesh exactly, it is not offset by the character's
radius: with a mesh from the builder the radius is already kept by the erosion step.

The search state (scores, parents and the open list) is allocated once per mesh, for all its
polygons, and reused by every query, so queries are not re-entrant: do not plan on the same mesh
from two isolates at once.


### Surface height

`sampleHeightAt(position)` returns the height of the mesh under a point, choosing the layer closest
to the point's own height where floors overlap (a bridge over a road), or `null` outside the mesh.
It tests only the polygons whose bounds the vertical line through the point crosses, found through
the bounding volume hierarchy, so it takes about a microsecond even on large meshes and can be
called for many objects every frame.


## Area costs

Every polygon has a cost multiplier, `1.0` by default, in `polygonCosts`. A* multiplies the length
of each step by the mean cost of the two polygons, so a cost of `3` makes mud three times as
expensive to cross as road, and paths go around it when the detour is shorter than three times the
direct way:

```dart
// Every polygon touching the box becomes mud.
final count = navMesh.setRegionCostInAabb(
  Aabb3.minMax(Vector3(-2, -1, -2), Vector3(2, 1, 2)),
  3.0,
);

// Or one polygon.
navMesh.setPolygonCost(hit.polyIndex, 0.5); // a road
```

Costs must be positive. Set them through `setPolygonCost` or `setRegionCostInAabb`: the search
scales its distance estimate by the lowest cost set through those methods. `polygonCosts` is a
read-only view, and writing into it throws an `UnsupportedError`. There are no area types or
per-agent filters: all agents share the costs of a mesh.


## Dynamic obstacles

A `NavMeshObstacle3D` is a box, optionally rotated, that blocks every polygon it intersects in 3D
until it moves away or is removed. Blocked polygons are skipped by every query: paths go around
them, and nearest-point queries snap to the closest unblocked polygon.

```dart
final cart = NavMeshObstacle3D(
  center: Vector3(0, 0.5, 0),
  halfExtents: Vector3(1.0, 0.5, 0.6),
  rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.3),
);
navMesh.addObstacle(cart);

// After moving, rotating, resizing or toggling it:
cart.center.setValues(3, 0.5, 0);
cart.enabled = true;
navMesh.updateObstacle(cart);

navMesh.removeObstacle(cart);
```

`NavMeshObstacle3D.fromAabb` makes an axis-aligned one. Adding or updating an obstacle finds the
polygons through the mesh's bounding volume hierarchy and tests each candidate triangle exactly
against the box; nothing is rebuilt. `blockedPolygonCount` and `isPolygonBlocked` tell what is
blocked. Overlapping obstacles are counted per polygon, so removing one does not unblock what
another still covers.

Obstacles block whole polygons, they do not cut them: on a mesh from the builder that means whole
`cellSize` squares, on a mesh from `fromMesh` whole input triangles, so a small crate on a floor
made of two triangles blocks the entire floor. The box is not grown by the character's radius;
make it larger by the radius if characters must not touch it. Paths that are already planned are
not updated: plan again after obstacles change.


## Off-mesh links

An `OffMeshLink3D` connects two points that walking cannot connect, such as a gap to jump, a ledge
to drop from, a ladder or a teleporter:

```dart
final jump = OffMeshLink3D(
  start: Vector3(-2.1, 0, 0),
  end: Vector3(2.1, 0, 0),
);
final ladder = OffMeshLink3D(
  start: Vector3(4, 0, 1.9),
  end: Vector3(4, 4, 3.1),
  bidirectional: false,
  costMultiplier: 1.5,
  linkTag: 'ladder',
);
navMesh
  ..addOffMeshLink(jump)
  ..addOffMeshLink(ladder);

for (final segment in navMesh.findSegmentedPath(from, to)) {
  if (segment.isOffMeshLink) {
    playTraversal(segment.linkTag!, segment.waypoints);
  } else {
    walk(segment.waypoints);
  }
}
```

Each end snaps to its nearest unblocked polygon the next time a path is searched. `snapRadius`
(default: no limit) is the farthest an end may be from that polygon; a link with an end farther
away, or whose ends snap to the same polygon, is ignored. Taking a link costs the distance
between its snapped ends times `costMultiplier` (default `1.0`), plus half the distances between
the link ends and the centroids of the polygons they snap to, weighted by those polygons' costs.
`bidirectional` (default `true`) allows both directions, and `linkTag` (default `'jump'`) is
returned with the segment. `findPath` returns the same points as `findSegmentedPath`, joined into
one list.

The snapping is redone at the next query whenever a link is added or removed, an obstacle is
added, updated or removed, or a link's `enabled`, `start` or `end` changed (including in place,
with `link.end.setValues(...)`). Each query compares the links with their state at the last
snapping, which costs a few comparisons per link.

While a mesh has links, A* runs without its distance estimate (as Dijkstra's algorithm), so that it
never misses a shortcut through a link; searches on large meshes with links visit more polygons.


## Crowd steering

`CrowdSteering3D` moves `CrowdAgent3D`s along their paths and keeps them from walking into each
other. Call its `update` from a component of your own:

```dart
class Villagers extends Component3D {
  Villagers(this.navMesh) : crowd = CrowdSteering3D(navMesh: navMesh);

  final NavMesh3D navMesh;
  final CrowdSteering3D crowd;

  void spawn(Vector3 at, Vector3 goal, Component3D body) {
    final agent = CrowdAgent3D(
      position: at,
      radius: 0.5,
      maxSpeed: 2.5,
      targetComponent: body, // its position follows the agent
    )..setDestination(goal, navMesh);
    crowd.addAgent(agent);
    add(body);
  }

  @override
  void update(double dt) {
    super.update(dt);
    crowd.update(dt);
  }
}
```

Each update, for every agent:

1. The preferred velocity points at the next waypoint of its path at `maxSpeed`, slowing down
   within `arrivalSlowingRadius` of the last one. A waypoint counts as reached within
   `waypointReachRadius` horizontally (the last one within `0.08` or half that radius, whichever
   is smaller).
2. When there are other agents, 40 candidate velocities (13 directions from -105 to +105 degrees
   around the preferred one, at three speeds, and standing still) are scored by how far they are
   from the preferred velocity, plus a penalty when a reciprocal velocity obstacle predicts a
   collision with another agent within `timeHorizon` seconds. Left turns get a small extra cost,
   so two agents meeting head-on both pass on their right.
3. The velocity changes toward the chosen one by at most `maxAcceleration * dt`, and the agent
   moves.

After moving, overlapping agents are pushed apart (two passes), and with a `navMesh` every agent
is put at the height of the mesh under it (`sampleHeightAt`, about a microsecond per agent), or
snapped to the nearest point of the mesh when it left it. Agents more than 1.5 units apart along
the up axis ignore each other, so crowds on two floors do not interact. `targetComponent`, when
set, gets the agent's position (not its rotation).

| `CrowdAgent3D` option  | Default | Meaning                                                  |
|------------------------|---------|----------------------------------------------------------|
| `radius`               | `0.4`   | Body radius for avoidance and separation.                |
| `maxSpeed`             | `3.5`   | Units per second.                                        |
| `maxAcceleration`      | `18.0`  | Units per second squared.                                |
| `waypointReachRadius`  | `0.25`  | Distance at which an intermediate waypoint is reached.   |
| `arrivalSlowingRadius` | `0.8`   | Distance to the goal at which the agent starts to brake. |
| `timeHorizon`          | `1.8`   | Seconds ahead that collisions are predicted.             |
| `separationWeight`     | `2.5`   | Weight of the collision penalty.                         |

`CrowdSteering3D` itself takes `navMesh` (optional), `upAxis` (default +Y) and `safetyMargin`
(default `0.04`, added to the sum of two radii). `setDestination` plans with `findPath`; `setPath`
takes any list of waypoints, `stop` clears the path, and `hasReachedGoal` tells when the agent is
done.

Agents only steer around each other. They do not see walls or obstacles; they rely on their paths
for that, and the paths are not planned again when obstacles change or when avoidance pushes an
agent far off its path. Re-plan with `setDestination` when that matters.


## Costs

The figures below were measured in a `flutter test` run (Dart JIT) on a desktop computer, on a
60 by 60 m floor with 40 boxes and random start and goal points; a release build is faster and a
phone slower, so read them as orders of magnitude.

| `cellSize` | Triangles | Build  | `findPath` | `sampleHeightAt` | `findNearestPoly` |
|------------|-----------|--------|------------|------------------|-------------------|
| `0.5`      | 25,022    | 103 ms | 1.2 ms     | 0.5 µs           | 1 µs              |
| `0.25`     | 110,476   | 236 ms | 5.9 ms     | 0.6 µs           | 1 µs              |

- `findPath` is mostly the A* search, which on these grids visits many polygons: a path with a
  clear straight line takes a fraction of a millisecond (0.3 ms across the empty 60 m floor), one
  around obstacles several milliseconds. Spread many queries over frames.
- The search state is allocated on the first query, about 33 bytes per polygon (110,000 polygons:
  about 3.6 MB), and reused afterwards.
- The first query of a mesh also builds its bounding volume hierarchy (the first `findPath` above
  took 33 ms).
- `CrowdSteering3D.update` scores 40 candidates against every other agent, which grows with the
  square of the number of agents: 50 agents took about 0.4 ms per update, with or without the
  110,000-triangle mesh.


## Debugging

The mesh's `vertices` and `polygons` (with `v0`, `v1`, `v2`, `centroid`, `normal` and `portals`)
are public, so it can be drawn with a `DebugRenderer3D` (see `debugging_and_testing.md`). Its
custom lines stay until `clearCustomSegments`, so draw the mesh once and again after obstacles
change:

```dart
void drawNavMesh(DebugRenderer3D debug, NavMesh3D navMesh) {
  debug.clearCustomSegments();
  for (final poly in navMesh.polygons) {
    final blocked = navMesh.isPolygonBlocked(poly.index);
    debug.drawPolyline(
      [
        navMesh.vertices[poly.v0],
        navMesh.vertices[poly.v1],
        navMesh.vertices[poly.v2],
      ],
      closed: true,
      color: blocked ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
    );
  }
}
```

Each triangle adds three line segments, so draw only a part of a large mesh. To see why a path
looks wrong, draw `findCentroidPath` next to `findPath`: the first shows the corridor the search
chose, the second what the funnel made of it. `polyCount`, `blockedPolygonCount` and
`offMeshLinks` give counts to log.


## Scenes with Z up

`NavMeshBuilder3D` assumes +Y up. A scene that uses Z up, as a `Scene3DComponent` layer drawn over
2D art often does (see `embedding.md`), can still use it by rotating the geometry into a Y-up frame
with the source transform, and the query points and results back:

```dart
final toYUp = Matrix4.rotationX(-math.pi / 2); // (x, y, z) -> (x, z, -y)
final toZUp = Matrix4.rotationX(math.pi / 2);

final zUpMesh = NavMeshBuilder3D.fromGeometry([
  NavMeshGeometrySource3D(
    positions: levelPositions,
    indices: levelIndices,
    transform: toYUp,
  ),
]);

List<Vector3> findZUpPath(Vector3 from, Vector3 to) {
  return zUpMesh
      .findPath(toYUp.transformed3(from), toYUp.transformed3(to))
      .map(toZUp.transformed3)
      .toList();
}
```

`NavMesh3D.fromMesh` and `CrowdSteering3D` take an `upAxis` and need no conversion; the agents of a
crowd steering on a converted mesh must use the same Y-up frame as the mesh.


## Limitations

- The builder stops after erosion: there is no region partitioning, no contour tracing and no
  polygon simplification, so meshes are grids of small squares with many more polygons than a
  Recast mesh of the same level, and A* searches cost accordingly.
- Paths are the shortest through the open regions A* picked, not always the shortest overall:
  around a group of obstacles the search can pick a longer way round.
- The builder is +Y up only, and floors must be wound counter-clockwise seen from above; floors
  with the other winding are silently dropped.
- Obstacles block whole polygons and are not grown by the agent radius; nothing is carved or
  rebuilt.
- Area costs are shared by all agents; there are no area types, flags or query filters.
- Queries on one mesh are not re-entrant (they share the mesh's search state).
- `CrowdSteering3D` avoids other agents only, never re-plans, and is quadratic in the number of
  agents.
