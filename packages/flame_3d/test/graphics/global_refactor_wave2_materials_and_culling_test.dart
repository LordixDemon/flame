import 'dart:math' as math;
import 'dart:ui' show Color, Size;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/parser/obj/surface_tool.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show makePerspectiveMatrix, makeViewMatrix;

import '../_fakes/fake_gpu_backend.dart';

bool _referenceConeReachesSphere(
  double x,
  double y,
  double z,
  double ax,
  double ay,
  double az,
  double outer,
  double cx,
  double cy,
  double cz,
  double radius,
) {
  final vx = cx - x;
  final vy = cy - y;
  final vz = cz - z;
  final distance = math.sqrt(vx * vx + vy * vy + vz * vz);
  if (distance <= radius) {
    return true;
  }
  final spread = outer + math.asin(radius / distance);
  if (spread >= math.pi) {
    return true;
  }
  return (vx * ax + vy * ay + vz * az) >= distance * math.cos(spread);
}

void main() {
  group('Wave 2.1 materials, light culling, and SurfaceTool', () {
    test(
      'BarrierMaterial.applyLookLerp batches change notifications and '
      'viewer-only pass changes skip rewriting BarrierShape',
      () {
        final material = BarrierMaterial();
        const lookA = BarrierLook(intensity: 0.5, fillOpacity: 0.2);
        const lookB = BarrierLook(
          intensity: 2.0,
          fillOpacity: 0.8,
          wobbleAmplitude: 0.2,
          patternScale: 3.0,
        );
        final startVersion = material.version;
        material.applyLookLerp(lookA, lookB, 0.5);
        expect(material.version, startVersion + 1);

        final backend = FakeGpuBackend(blockSize: 64 * 1024);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final mesh = BarrierMesh.ring(
          radius: 2.0,
          height: 2.0,
          material: material,
        );

        final viewA = makeViewMatrix(
          Vector3(1, 2, 6),
          Vector3.zero(),
          Vector3(0, 1, 0),
        );
        final viewB = makeViewMatrix(
          Vector3(4, 3, 8),
          Vector3.zero(),
          Vector3(0, 1, 0),
        );
        final proj = makePerspectiveMatrix(1.0, 1.5, 0.2, 50.0);

        device.begin();
        context.setCamera(viewA, proj);
        device.beginPass(const Size(16, 16));
        context
          ..drawMesh(mesh)
          ..flush();
        device.endPass();

        final vert = material.vertexShaderFor(BarrierMesh.layout);
        final frag = material.fragmentShader;
        expect(material.isApplyCacheValid(context, vert, frag), isTrue);

        // Next camera pass only changes the camera/pass (`BarrierShape` stays
        // clean when `apply` runs the viewer-only fast-path).
        final shapeIdx = vert.blockIndexOf('BarrierShape');
        expect(shapeIdx, greaterThanOrEqualTo(0));
        final shapeBlock = vert.blockAt(shapeIdx);
        expect(shapeBlock.isDirty, isFalse);

        context.setCamera(viewB, proj);
        device.beginPass(const Size(16, 16));
        expect(material.isApplyCacheValid(context, vert, frag), isFalse);
        context
          ..drawMesh(mesh)
          ..flush();
        device.endPass();
        device.end();

        expect(shapeBlock.isDirty, isFalse);
        final lookIdx = frag.blockIndexOf('BarrierLook');
        final lookBlock = frag.blockAt(lookIdx);
        final viewerOff = lookBlock.resolveOffset('viewer');
        expect(viewerOff, greaterThanOrEqualTo(0));
        expect(lookBlock.data[viewerOff], closeTo(4.0, 1e-4));
        expect(lookBlock.data[viewerOff + 1], closeTo(3.0, 1e-4));
        expect(lookBlock.data[viewerOff + 2], closeTo(8.0, 1e-4));
      },
    );

    test(
      'DecalMaterial, ShadowCatcherMaterial, and OutlineMaterial cache apply '
      'and invalidate on property or aspect changes',
      () {
        final backend = FakeGpuBackend(blockSize: 64 * 1024);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final view = makeViewMatrix(
          Vector3(0, 2, 5),
          Vector3.zero(),
          Vector3(0, 1, 0),
        );
        final projNarrow = makePerspectiveMatrix(1.0, 1.5, 0.2, 50.0);
        final projWide = makePerspectiveMatrix(1.0, 2.5, 0.2, 50.0);

        final decal = DecalMaterial();
        final shadowCatcher = ShadowCatcherMaterial();
        final outline = OutlineMaterial();

        final decalMesh = PlaneMesh(size: Vector2.all(1), material: decal);
        final catcherMesh = PlaneMesh(
          size: Vector2.all(1),
          material: shadowCatcher,
        );
        final outlineMesh = PlaneMesh(size: Vector2.all(1), material: outline);

        device.begin();
        context.setCamera(view, projNarrow);
        device.beginPass(const Size(16, 16));

        final decalLayout = decalMesh.surfaces.single.layout;
        final catcherLayout = catcherMesh.surfaces.single.layout;
        final outlineLayout = outlineMesh.surfaces.single.layout;

        context
          ..drawMesh(decalMesh)
          ..flush();
        final afterDecal = device.stats.uniformUploads;
        context
          ..drawMesh(decalMesh)
          ..flush();
        expect(device.stats.uniformUploads, afterDecal);
        decal.depthBias = 0.002;
        expect(
          decal.isApplyCacheValid(
            context,
            decal.vertexShaderFor(decalLayout),
            decal.fragmentShader,
          ),
          isFalse,
        );

        context
          ..drawMesh(catcherMesh)
          ..flush();
        final afterCatcher = device.stats.uniformUploads;
        context
          ..drawMesh(catcherMesh)
          ..flush();
        expect(device.stats.uniformUploads, afterCatcher);
        shadowCatcher.color = const Color(0xAA223344);
        expect(
          shadowCatcher.isApplyCacheValid(
            context,
            shadowCatcher.vertexShaderFor(catcherLayout),
            shadowCatcher.fragmentShader,
          ),
          isFalse,
        );

        context
          ..drawMesh(outlineMesh)
          ..flush();
        final afterOutline = device.stats.uniformUploads;
        context
          ..drawMesh(outlineMesh)
          ..flush();
        expect(device.stats.uniformUploads, afterOutline);
        final outlineVert = outline.vertexShaderFor(outlineLayout);
        expect(
          outline.isApplyCacheValid(
            context,
            outlineVert,
            outline.fragmentShader,
          ),
          isTrue,
        );

        // Changing projection aspect ratio invalidates OutlineMaterial cache.
        context.setCamera(view, projWide);
        expect(
          outline.isApplyCacheValid(
            context,
            outlineVert,
            outline.fragmentShader,
          ),
          isFalse,
        );

        device
          ..endPass()
          ..end();
      },
    );

    test(
      'LightClusterGrid3D spotlight assignment uses cached bounding spheres '
      'and matches analytical cone-sphere intersection',
      () {
        final grid = LightClusterGrid3D(
          clustersX: 4,
          clustersY: 3,
          clustersZ: 4,
        );
        const outerNarrow = math.pi / 6;
        grid
          ..addLight(
            ClusterLightEntry3D.spot(
              position: Vector3(0, 0, -2),
              direction: Vector3(0, 0, -1),
              range: 18.0,
              outerConeAngle: outerNarrow,
            ),
          )
          ..addLight(
            ClusterLightEntry3D.point(
              position: Vector3(2, 1, -8),
              range: 6.0,
            ),
          );

        grid.assignLights(
          Matrix4.identity(),
          makePerspectiveMatrix(1.0, 4 / 3, 0.5, 30.0),
          near: 0.5,
          far: 30.0,
        );

        var assignedSpotClusters = 0;
        final bounds = Aabb3();
        for (var c = 0; c < grid.totalClusters; c++) {
          grid.clusterViewBounds(c, out: bounds);
          final cx = 0.5 * (bounds.min.x + bounds.max.x);
          final cy = 0.5 * (bounds.min.y + bounds.max.y);
          final cz = 0.5 * (bounds.min.z + bounds.max.z);
          final hx = 0.5 * (bounds.max.x - bounds.min.x);
          final hy = 0.5 * (bounds.max.y - bounds.min.y);
          final hz = 0.5 * (bounds.max.z - bounds.min.z);
          final r = math.sqrt(hx * hx + hy * hy + hz * hz);

          final assigned = grid.lightsForCluster(c);
          final hasSpot = assigned.contains(0);
          if (hasSpot) {
            assignedSpotClusters++;
          }

          // Any cluster assigned to spot light 0 must intersect both its
          // range AABB and its analytical cone-sphere volume.
          if (hasSpot) {
            expect(
              _referenceConeReachesSphere(
                0,
                0,
                -2,
                0,
                0,
                -1,
                outerNarrow,
                cx,
                cy,
                cz,
                r,
              ),
              isTrue,
            );
          }
        }
        expect(assignedSpotClusters, greaterThan(0));
        expect(assignedSpotClusters, lessThan(grid.totalClusters));
      },
    );

    test('SurfaceTool propagates optional per-vertex tangents cleanly', () {
      final tool = SurfaceTool();
      final t0 = Vector4(1, 0, 0, 1);
      final t1 = Vector4(0, 1, 0, -1);
      final t2 = Vector4(0, 0, 1, 1);

      tool.addTriangleFan(
        [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)],
        [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)],
        [Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)],
        const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
        [t0, t1, t2],
      );
      final mesh = tool.apply();
      final surface = mesh.surfaces.single;
      expect(surface.vertexCount, 3);
      expect(surface.layout, VertexLayout.pbrStandard);
      final stride = surface.layout.strideInFloats;
      final tOff = surface.layout.offsetOf(VertexLayout.tangentAttribute)!;
      final data = surface.vertexData;
      expect(
        [data[tOff], data[tOff + 1], data[tOff + 2], data[tOff + 3]],
        const [1.0, 0.0, 0.0, 1.0],
      );
      expect(
        [
          data[stride + tOff],
          data[stride + tOff + 1],
          data[stride + tOff + 2],
          data[stride + tOff + 3],
        ],
        const [0.0, 1.0, 0.0, -1.0],
      );
      expect(
        [
          data[2 * stride + tOff],
          data[2 * stride + tOff + 1],
          data[2 * stride + tOff + 2],
          data[2 * stride + tOff + 3],
        ],
        const [0.0, 0.0, 1.0, 1.0],
      );
    });
  });
}
