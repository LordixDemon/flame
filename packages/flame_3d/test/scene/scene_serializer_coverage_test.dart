import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// Saves [world] as JSON and as F3DS binary with [serializer], loads both,
/// and returns the two loaded worlds.
List<World3D> _roundTrip(SceneSerializer3D serializer, World3D world) {
  final fromJson = World3D();
  serializer.decodeJsonInto(serializer.encodeJson(world), fromJson);
  final fromBinary = World3D();
  serializer.decodeBinaryInto(serializer.encodeBinary(world), fromBinary);
  return [fromJson, fromBinary];
}

void _expectSameSurfaces(Mesh actual, Mesh expected) {
  final a = actual.surfaces.toList();
  final b = expected.surfaces.toList();
  expect(a.length, b.length);
  for (var i = 0; i < a.length; i++) {
    expect(a[i].layout, b[i].layout);
    expect(a[i].topology, b[i].topology);
    expect(a[i].vertexData.length, b[i].vertexData.length);
    for (var k = 0; k < a[i].vertexData.length; k++) {
      expect(a[i].vertexData[k], closeTo(b[i].vertexData[k], 1e-5));
    }
    expect(a[i].indices, b[i].indices);
  }
}

/// A surface of three vertices laid out as [VertexLayout.pbrStandard].
Surface _pbrSurface(Material material) {
  final layout = VertexLayout.pbrStandard;
  final stride = layout.strideInFloats;
  final vertices = Float32List(3 * stride);
  for (var v = 0; v < 3; v++) {
    for (var k = 0; k < stride; k++) {
      vertices[v * stride + k] = v * 0.25 + k * 0.01;
    }
  }
  return Surface.fromBuffers(
    vertices: vertices,
    indices: Uint16List.fromList([0, 1, 2]),
    layout: layout,
    material: material,
  );
}

class _SubclassedSpatial() extends SpatialMaterial;

class _UnknownObject() extends Object3D {
  @override
  void draw(RenderContext context) {}
}

class _PlainComponent() extends Component;

void main() {
  setUp(FakeGpuBackend.new);

  group('SceneSerializer3D round-trips every built-in type', () {
    test('LodMeshComponent keeps its levels, shadow mesh and values', () {
      final near = CuboidMesh(size: Vector3.all(1));
      final far = SphereMesh(radius: 0.5, segments: 6);
      final shadow = CuboidMesh(size: Vector3.all(0.5));
      final world = World3D(
        children: [
          LodMeshComponent(
            levels: [
              MeshLodLevel(mesh: near, maxDistance: 12),
              MeshLodLevel(mesh: far, minScreenHeightRatio: 0.05),
            ],
            shadowMesh: shadow,
            lowestLodInShadowPass: true,
            color: const Color(0xFF336699),
            instanceData: Vector4(1, 2, 3, 4),
            castsShadows: false,
            position: Vector3(3, 0, 1),
          ),
        ],
      );
      for (final loaded in _roundTrip(SceneSerializer3D(), world)) {
        final lod = loaded.children.single as LodMeshComponent;
        expect(lod.levels, hasLength(2));
        expect(lod.levels[0].maxDistance, 12);
        expect(lod.levels[1].maxDistance, double.infinity);
        expect(lod.levels[1].minScreenHeightRatio, closeTo(0.05, 1e-9));
        _expectSameSurfaces(lod.levels[0].mesh, near);
        _expectSameSurfaces(lod.levels[1].mesh, far);
        _expectSameSurfaces(lod.shadowMesh!, shadow);
        expect(lod.lowestLodInShadowPass, isTrue);
        expect(lod.color, const Color(0xFF336699));
        expect(lod.instanceData, Vector4(1, 2, 3, 4));
        expect(lod.castsShadows, isFalse);
        expect(lod.position, Vector3(3, 0, 1));
      }
    });

    test('InstancedGroup3D keeps transforms, colors and instance data', () {
      final group = InstancedGroup3D(mesh: CuboidMesh(size: Vector3.all(1)));
      for (var i = 0; i < 5; i++) {
        group.addInstance(
          transform: Matrix4.translationValues(i * 2.0, 0, -i * 1.0),
          color: Color.from(alpha: 1, red: i / 4, green: 0.5, blue: 0),
          instanceData: Vector4(i * 1.0, 0.5, 0.25, 1),
        );
      }
      final world = World3D(children: [group]);
      for (final loaded in _roundTrip(SceneSerializer3D(), world)) {
        final copy = loaded.children.single as InstancedGroup3D;
        expect(copy.length, 5);
        for (var i = 0; i < 5; i++) {
          expect(copy.instanceTransform(i), group.instanceTransform(i));
          expect(copy.instanceColor(i), group.instanceColor(i));
          expect(copy.instanceDataAt(i), group.instanceDataAt(i));
        }
      }
    });

    test('ShadowCatcherMaterial comes back as a shadow catcher', () {
      final world = World3D(
        children: [
          MeshComponent(
            mesh: PlaneMesh(
              size: Vector2.all(10),
              material: ShadowCatcherMaterial(color: const Color(0x66102030)),
            ),
          ),
        ],
      );
      for (final loaded in _roundTrip(SceneSerializer3D(), world)) {
        final mesh = (loaded.children.single as MeshComponent).mesh;
        final material = mesh.surfaces.single.material;
        expect(material, isA<ShadowCatcherMaterial>());
        material as ShadowCatcherMaterial;
        expect(material.color, const Color(0x66102030));
        expect(material.renderState, RenderState.premultipliedAlphaBlend);
      }
    });

    test('point light shadows and cascade settings round-trip', () {
      final world = World3D(
        children: [
          LightComponent(
            source: PointLight(
              color: const Color(0xFFFFEEDD),
              intensity: 3,
              range: 8,
              shadows: ShadowSettings(resolution: 512, softness: 2),
            ),
          ),
          LightComponent(
            source: DirectionalLight(
              shadows: ShadowSettings(
                cascades: 3,
                cascadeSplits: [0.1, 0.4],
                cascadeBlendRange: 0.2,
              ),
            ),
          ),
        ],
      );
      for (final loaded in _roundTrip(SceneSerializer3D(), world)) {
        final lights = loaded.children.whereType<LightComponent>().toList();
        final point = lights[0].source as PointLight;
        expect(point.shadows, isNotNull);
        expect(point.shadows!.resolution, 512);
        expect(point.shadows!.softness, 2);
        final sun = lights[1].source as DirectionalLight;
        expect(sun.shadows!.cascadeSplits, [0.1, 0.4]);
        expect(sun.shadows!.cascadeBlendRange, closeTo(0.2, 1e-9));
      }
    });

    test(
      'primitives keep their segment counts and are saved as primitives',
      () {
        final meshes = <Mesh>[
          CuboidMesh(size: Vector3(1, 2, 3), useFaceNormals: false),
          SphereMesh(radius: 0.7, segments: 9),
          CylinderMesh(radius: 0.3, height: 2, segments: 7),
          ConeMesh(
            radius: 0.4,
            height: 1,
            segments: 11,
            material: UnlitMaterial(),
          ),
          PlaneMesh(size: Vector2(4, 2)),
          CapsuleMesh(
            radius: 0.3,
            height: 1.4,
            segments: 5,
            hemisphereRings: 2,
          ),
          TorusMesh(majorSegments: 9, minorSegments: 5),
        ];
        final world = World3D(
          children: [for (final mesh in meshes) MeshComponent(mesh: mesh)],
        );
        final serializer = SceneSerializer3D();
        final json = serializer.toJson(world);
        final kinds = [
          for (final node in json['nodes']! as List)
            ((node as Map)['mesh'] as Map)['kind'],
        ];
        expect(kinds, [
          'cuboid',
          'sphere',
          'cylinder',
          'cone',
          'plane',
          'capsule',
          'torus',
        ]);
        for (final loaded in _roundTrip(serializer, world)) {
          final restored = loaded.children.cast<MeshComponent>().toList();
          for (var i = 0; i < meshes.length; i++) {
            _expectSameSurfaces(restored[i].mesh, meshes[i]);
          }
        }
      },
    );

    test('a changed primitive is saved vertex by vertex', () {
      final material = SpatialMaterial();
      final cuboid = CuboidMesh(size: Vector3.all(1), material: material)
        ..addSurface(_pbrSurface(material));
      final world = World3D(children: [MeshComponent(mesh: cuboid)]);
      final serializer = SceneSerializer3D();
      final node = (serializer.toJson(world)['nodes']! as List).single as Map;
      expect((node['mesh'] as Map)['kind'], 'raw');
      for (final loaded in _roundTrip(serializer, world)) {
        _expectSameSurfaces(
          (loaded.children.single as MeshComponent).mesh,
          cuboid,
        );
      }
    });

    test('raw surfaces keep their vertex layout and topology', () {
      final material = SpatialMaterial();
      final mesh = Mesh()
        ..addSurface(_pbrSurface(material))
        ..addSurface(
          Surface.fromBuffers(
            vertices: Float32List(2 * VertexLayout.standard.strideInFloats),
            indices: Uint16List.fromList([0, 1]),
            material: material,
            topology: PrimitiveTopology.lines,
          ),
        );
      final world = World3D(children: [MeshComponent(mesh: mesh)]);
      for (final loaded in _roundTrip(SceneSerializer3D(), world)) {
        final restored = (loaded.children.single as MeshComponent).mesh;
        _expectSameSurfaces(restored, mesh);
        expect(
          identical(restored.surfaces.first.layout, VertexLayout.pbrStandard),
          isTrue,
        );
      }
    });

    test('meshes and materials shared by several components stay shared', () {
      final material = SpatialMaterial(albedoColor: const Color(0xFF00FF00));
      final mesh = SphereMesh(radius: 1, segments: 8, material: material);
      final other = CuboidMesh(size: Vector3.all(1), material: material);
      final world = World3D(
        children: [
          MeshComponent(mesh: mesh),
          MeshComponent(mesh: mesh),
          MeshComponent(mesh: other),
        ],
      );
      for (final loaded in _roundTrip(SceneSerializer3D(), world)) {
        final restored = loaded.children.cast<MeshComponent>().toList();
        expect(identical(restored[0].mesh, restored[1].mesh), isTrue);
        expect(
          identical(
            restored[0].mesh.surfaces.first.material,
            restored[2].mesh.surfaces.first.material,
          ),
          isTrue,
        );
      }
    });

    test('material values beyond the old subset round-trip', () {
      final normals = ColorTexture(const Color(0xFF8080FF));
      final matCap = ColorTexture(const Color(0xFFCCCCCC));
      final serializer = SceneSerializer3D()
        ..registerTexture('normals', normals)
        ..registerTexture('matcap', matCap);
      final world = World3D(
        hdrEnabled: true,
        oitMode: OitMode3D.weightedBlended,
        children: [
          MeshComponent(
            mesh: CuboidMesh(
              size: Vector3.all(1),
              material: SpatialMaterial(
                normalTexture: normals,
                clearcoat: 0.7,
                transmission: 0.3,
                ior: 1.33,
              ),
            ),
          ),
          MeshComponent(
            mesh: CuboidMesh(
              size: Vector3.all(2),
              material:
                  StylizedMaterial(
                      matCapTexture: matCap,
                      matCapStrength: 0.6,
                      windGustAmplitude: 0.2,
                      windTime: 3,
                    )
                    ..renderState = const RenderState(
                      polygonMode: PolygonFillMode.wireframe,
                    ),
            ),
          ),
        ],
      );
      for (final loaded in _roundTrip(serializer, world)) {
        expect(loaded.hdrEnabled, isTrue);
        expect(loaded.oitMode, OitMode3D.weightedBlended);
        final meshes = loaded.children.cast<MeshComponent>().toList();
        final spatial =
            meshes[0].mesh.surfaces.first.material as SpatialMaterial;
        expect(spatial.normalTexture, same(normals));
        expect(spatial.clearcoat, closeTo(0.7, 1e-9));
        expect(spatial.transmission, closeTo(0.3, 1e-9));
        expect(spatial.ior, closeTo(1.33, 1e-9));
        final stylized =
            meshes[1].mesh.surfaces.first.material as StylizedMaterial;
        expect(stylized.matCapTexture, same(matCap));
        expect(stylized.matCapStrength, closeTo(0.6, 1e-9));
        expect(stylized.windGustAmplitude, closeTo(0.2, 1e-9));
        expect(stylized.windTime, 3);
        expect(stylized.renderState.polygonMode, PolygonFillMode.wireframe);
      }
    });
  });

  group('SceneSerializer3D reports what it cannot represent', () {
    World3D unrepresentable() => World3D(
      children: [
        Group3D(children: [_UnknownObject()..addTag3D('kept')]),
        MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: _SubclassedSpatial(),
          ),
        ),
        MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: UnlitMaterial(
              albedoTexture: ColorTexture(const Color(0xFF123456)),
            ),
          ),
        ),
      ],
    )..add(_PlainComponent());

    test('a save throws and lists every unrepresentable item', () {
      final serializer = SceneSerializer3D();
      final world = unrepresentable();
      expect(
        () => serializer.toJson(world),
        throwsA(
          isA<SceneSerializationException3D>().having(
            (e) => e.issues.map((issue) => issue.path).toList(),
            'paths',
            [
              'nodes[0].children[0]',
              'nodes[1].mesh.surfaces[0].material',
              'nodes[2].mesh.surfaces[0].material.albedoTexture',
              'nodes[3]',
            ],
          ),
        ),
      );
      expect(() => serializer.encodeBinary(world), throwsA(anything));
      expect(serializer.findIssues(world), hasLength(4));
      expect(
        serializer.findIssues(World3D(children: [Group3D()])),
        isEmpty,
      );
    });

    test('a lossy save writes what it can and keeps the list', () {
      final serializer = SceneSerializer3D(allowLossy: true);
      final loaded = World3D();
      serializer.decodeJsonInto(
        serializer.encodeJson(unrepresentable()),
        loaded,
      );
      expect(serializer.lastIssues, hasLength(4));
      final group = loaded.children.first as Group3D;
      expect(group.children.single, isA<Group3D>());
      expect((group.children.single as Group3D).hasTag3D('kept'), isTrue);
      expect(loaded.children, hasLength(3));
    });

    test('a load that fails leaves the target unchanged', () {
      final serializer = SceneSerializer3D();
      final json = serializer.toJson(
        World3D(children: [Group3D(), Group3D()]),
      );
      ((json['nodes']! as List)[1] as Map)['type'] = 'prefab';
      ((json['nodes']! as List)[1] as Map)['prefabId'] = 'missing';
      final target = World3D(children: [Group3D()]);
      expect(
        () => serializer.fromJsonInto(json, target, clearTarget: true),
        throwsStateError,
      );
      expect(target.children, hasLength(1));
    });

    test('schema version 1 snapshots still load', () {
      final target = World3D();
      SceneSerializer3D().fromJsonInto({
        'schemaVersion': 1,
        'nodes': [
          {
            'type': 'mesh',
            'mesh': {
              'kind': 'raw',
              'surfaces': [
                {
                  'vertices': List<double>.filled(
                    3 * VertexLayout.standard.strideInFloats,
                    0,
                  ),
                  'indices': [0, 1, 2],
                  'material': {'kind': 'unlit'},
                },
              ],
            },
          },
        ],
      }, target);
      final mesh = (target.children.single as MeshComponent).mesh;
      expect(mesh.surfaces.single.vertexCount, 3);
      expect(mesh.surfaces.single.material, isA<UnlitMaterial>());
    });
  });
}
