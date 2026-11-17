import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

const _flat = Material3D.unshaded();

Future<ByteData> _rasterize(
  void Function(Canvas canvas) paint, {
  int size = 240,
}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF000000), BlendMode.src)
    ..translate(size / 2, size / 2);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  final bytes = await image.toByteData();
  image.dispose();
  picture.dispose();
  return bytes!;
}

int _differingPixels(ByteData a, ByteData b, {int tolerance = 3}) {
  var n = 0;
  for (var i = 0; i < a.lengthInBytes; i += 4) {
    for (var c = 0; c < 3; c++) {
      if ((a.getUint8(i + c) - b.getUint8(i + c)).abs() > tolerance) {
        n++;
        break;
      }
    }
  }
  return n;
}

int _litPixels(ByteData bytes) {
  var lit = 0;
  for (var i = 0; i < bytes.lengthInBytes; i += 4) {
    if (bytes.getUint8(i) + bytes.getUint8(i + 1) + bytes.getUint8(i + 2) >
        60) {
      lit++;
    }
  }
  return lit;
}

/// Row-major `3x3` product `a * b`.
List<double> _mul(List<double> a, List<double> b) {
  final out = List<double>.filled(9, 0);
  for (var r = 0; r < 3; r++) {
    for (var c = 0; c < 3; c++) {
      var sum = 0.0;
      for (var k = 0; k < 3; k++) {
        sum += a[r * 3 + k] * b[k * 3 + c];
      }
      out[r * 3 + c] = sum;
    }
  }
  return out;
}

List<double> _euler(double yaw, double pitch, double roll) {
  final m = Float32List(9);
  Quaternion3D.writeEulerMatrix3(
    yawRad: yaw,
    pitchRad: pitch,
    rollRad: roll,
    out: m,
  );
  return m.toList();
}

List<double> _diag(double x, double y, double z) => [x, 0, 0, 0, y, 0, 0, 0, z];

void main() {
  group('Node3D world transform', () {
    test('a rotated child under a non-uniformly scaled parent is scaled along '
        'the parent axes', () {
      // The parent stretches world X by 2. The child is yawed 90 degrees, so
      // its local +X points along world +Y, which the parent does not stretch.
      final parent = Node3D(localScaleX: 2.0);
      final child = Node3D(localYawRad: math.pi / 2);
      parent
        ..addChild(child)
        ..updateWorldTransforms();

      final (wx, wy, wz) = child.worldPointForLocal(1, 0, 0);
      expect(wx, closeTo(0.0, 1e-6));
      expect(wy, closeTo(1.0, 1e-6));
      expect(wz, closeTo(0.0, 1e-6));

      // Its local +Y points along world -X, which is stretched.
      final (ux, uy, uz) = child.worldPointForLocal(0, 1, 0);
      expect(ux, closeTo(-2.0, 1e-6));
      expect(uy, closeTo(0.0, 1e-6));
      expect(uz, closeTo(0.0, 1e-6));
    });

    test('a three-level chain equals the matrix product '
        'parent * translation * rotation * scale', () {
      final rnd = math.Random(9);
      double angle() => rnd.nextDouble() * 6 - 3;
      double scale() => 0.4 + rnd.nextDouble() * 2;
      for (var iter = 0; iter < 50; iter++) {
        final nodes = <Node3D>[];
        var linear = _diag(1, 1, 1);
        var rotation = _diag(1, 1, 1);
        var origin = <double>[0, 0, 0];
        for (var level = 0; level < 3; level++) {
          final yaw = angle();
          final pitch = angle();
          final roll = angle();
          final sx = scale();
          final sy = scale();
          final sz = iter.isEven ? scale() : -scale();
          final tx = angle();
          final ty = angle();
          final tz = angle();
          final node = Node3D(
            localX: tx,
            localY: ty,
            localZ: tz,
            localYawRad: yaw,
            localPitchRad: pitch,
            localRollRad: roll,
            localScaleX: sx,
            localScaleY: sy,
            localScaleZ: sz,
          );
          if (nodes.isNotEmpty) {
            nodes.last.addChild(node);
          }
          nodes.add(node);
          origin = [
            origin[0] + linear[0] * tx + linear[1] * ty + linear[2] * tz,
            origin[1] + linear[3] * tx + linear[4] * ty + linear[5] * tz,
            origin[2] + linear[6] * tx + linear[7] * ty + linear[8] * tz,
          ];
          final r = _euler(yaw, pitch, roll);
          rotation = _mul(rotation, r);
          linear = _mul(_mul(linear, r), _diag(sx, sy, sz));
        }
        nodes.first.updateWorldTransforms();
        final leaf = nodes.last;

        const lx = 0.3;
        const ly = -0.7;
        const lz = 1.1;
        final (wx, wy, wz) = leaf.worldPointForLocal(lx, ly, lz);
        expect(
          wx,
          closeTo(
            origin[0] + linear[0] * lx + linear[1] * ly + linear[2] * lz,
            1e-3,
          ),
        );
        expect(
          wy,
          closeTo(
            origin[1] + linear[3] * lx + linear[4] * ly + linear[5] * lz,
            1e-3,
          ),
        );
        expect(
          wz,
          closeTo(
            origin[2] + linear[6] * lx + linear[7] * ly + linear[8] * lz,
            1e-3,
          ),
        );
        for (var k = 0; k < 9; k++) {
          expect(leaf.worldLinearMatrix[k], closeTo(linear[k], 1e-3));
          // The rotation matrix stays a pure rotation product.
          expect(leaf.worldRotationMatrix[k], closeTo(rotation[k], 1e-4));
        }
        expect(
          leaf.worldScaleX,
          closeTo(
            nodes[0].localScaleX * nodes[1].localScaleX * nodes[2].localScaleX,
            1e-9,
          ),
        );
      }
    });

    test('without a rotation between different scales the linear matrix is '
        'worldRotationMatrix times the world scales', () {
      final parent = Node3D(localScaleX: 2, localScaleY: 2, localScaleZ: 2);
      final child = Node3D(
        localYawRad: 0.7,
        localPitchRad: -0.3,
        localScaleX: 1.5,
        localScaleZ: 0.5,
      );
      parent
        ..addChild(child)
        ..updateWorldTransforms();
      final scales = [child.worldScaleX, child.worldScaleY, child.worldScaleZ];
      expect(scales, [3.0, 2.0, 1.0]);
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 3; c++) {
          expect(
            child.worldLinearMatrix[r * 3 + c],
            closeTo(child.worldRotationMatrix[r * 3 + c] * scales[c], 1e-5),
          );
        }
      }
    });

    test('worldYawRad is the heading of the world rotation, however it was '
        'composed', () {
      final (qx, qy, qz, qw) = Quaternion3D.fromAxisAngle(0, 0, 1, 1.0);
      final byQuaternion = Node3D()
        ..setLocalQuaternion(qx, qy, qz, qw)
        ..updateWorldTransforms();
      expect(byQuaternion.worldYawRad, closeTo(1.0, 1e-6));

      final parent = Node3D(localYawRad: 0.4);
      final child = Node3D(localYawRad: 0.5);
      final grandChild = Node3D()..setLocalQuaternion(qx, qy, qz, qw);
      parent.addChild(child);
      child.addChild(grandChild);
      parent.updateWorldTransforms();
      expect(parent.worldYawRad, closeTo(0.4, 1e-6));
      expect(child.worldYawRad, closeTo(0.9, 1e-6));
      expect(grandChild.worldYawRad, closeTo(1.9, 1e-6));

      // Reported in (-pi, pi].
      final wrapped = Node3D(localYawRad: 4.0)..updateWorldTransforms();
      expect(wrapped.worldYawRad, closeTo(4.0 - 2 * math.pi, 1e-6));

      // A scale does not disturb it.
      final scaled = Node3D(localYawRad: 0.6, localScaleX: 3)
        ..updateWorldTransforms();
      expect(scaled.worldYawRad, closeTo(0.6, 1e-6));
    });

    test('enqueueHierarchy draws a sheared child where worldPointForLocal '
        'puts its corners', () async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final parent = Node3D(localScaleX: 2.5);
      final child = Node3D(
        localYawRad: math.pi / 4,
        mesh: Mesh3D.plane(),
        material: _flat,
        emissive: 1,
      );
      parent.addChild(child);

      final renderer = BatchMeshRenderer3D(
        shadowsEnabled: false,
        backfaceCulling: false,
      )..beginBatch();
      parent.enqueueHierarchy(renderer, camera: rig);
      expect(renderer.pendingGeometryTriangleCount, 2);
      final bytes = await _rasterize(renderer.flushBatch);

      bool litAtLocal(double lx, double ly) {
        final (wx, wy, wz) = child.worldPointForLocal(lx, ly, 0);
        final s = rig.projectWorldPoint(wx, wy, wz);
        final px = (s.dx + 120).round();
        final py = (s.dy + 120).round();
        final o = (py * 240 + px) * 4;
        return bytes.getUint8(o) > 100;
      }

      // Just inside each corner of the unit quad it is lit ...
      expect(litAtLocal(0.42, 0.42), isTrue);
      expect(litAtLocal(-0.42, 0.42), isTrue);
      expect(litAtLocal(0.42, -0.42), isTrue);
      expect(litAtLocal(-0.42, -0.42), isTrue);
      // ... and just outside it is not.
      expect(litAtLocal(0.6, 0.6), isFalse);
      expect(litAtLocal(-0.6, 0.6), isFalse);
      expect(litAtLocal(0.6, 0), isFalse);
      expect(litAtLocal(0, -0.6), isFalse);
    });
  });

  group('BatchMeshRenderer3D with a general rotationMatrix3', () {
    final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
    final box = Mesh3D.box(sizeX: 0.8, sizeY: 0.6, sizeZ: 0.5, centerZ: 0.25);

    Future<ByteData> draw({
      Mesh3D? mesh,
      Float32List? matrix,
      double scaleX = 1,
      double scaleY = 1,
      double scaleZ = 1,
      double yawRad = 0,
    }) {
      final renderer = BatchMeshRenderer3D()..beginBatch();
      renderer.enqueueMesh(
        mesh ?? box,
        camera: rig,
        worldX: 0,
        worldY: 0,
        scaleX: scaleX,
        scaleY: scaleY,
        scaleZ: scaleZ,
        yawRad: yawRad,
        rotationMatrix3: matrix,
        tint: const Color(0xFFE0C090),
        castGroundShadow: true,
      );
      return _rasterize(renderer.flushBatch);
    }

    test('a scale inside the matrix lights and culls like the scale '
        'parameters', () async {
      final viaParams = await draw(scaleX: 1.5, scaleZ: 3);
      final viaMatrix = await draw(
        matrix: Float32List.fromList(_diag(1.5, 1, 3)),
      );
      expect(_litPixels(viaParams), greaterThan(2000));
      expect(_differingPixels(viaParams, viaMatrix), 0);
    });

    test('a mirror inside the matrix flips winding and normals like a '
        'negative scale', () async {
      final viaParams = await draw(scaleX: -1, yawRad: 0.4);
      final yaw = _euler(0.4, 0, 0);
      final viaMatrix = await draw(
        matrix: Float32List.fromList(_mul(yaw, _diag(-1, 1, 1))),
      );
      expect(_litPixels(viaParams), greaterThan(1000));
      expect(_differingPixels(viaParams, viaMatrix), 0);
    });

    test('a sheared matrix shades faces by their true normals', () async {
      // Shear X by Z: the side faces lean, so their normals change.
      final shear = <double>[1, 0, 0.8, 0, 1, 0, 0, 0, 1];
      final viaMatrix = await draw(matrix: Float32List.fromList(shear));

      // Reference: the same box with the shear baked into its vertices and
      // its flat normals recomputed from the sheared triangles.
      final positions = Float32List(box.positions.length);
      for (var i = 0; i < positions.length; i += 3) {
        final x = box.positions[i];
        final y = box.positions[i + 1];
        final z = box.positions[i + 2];
        positions[i] = shear[0] * x + shear[1] * y + shear[2] * z;
        positions[i + 1] = shear[3] * x + shear[4] * y + shear[5] * z;
        positions[i + 2] = shear[6] * x + shear[7] * y + shear[8] * z;
      }
      final baked = Mesh3D.fromRaw(
        positions: positions,
        indices: box.indices,
        ambientOcclusion: box.ambientOcclusion,
        uvs: box.uvs,
      );
      final reference = await draw(mesh: baked);

      expect(_litPixels(reference), greaterThan(1500));
      expect(_differingPixels(reference, viaMatrix), 0);
    });

    test('frustum culling accounts for a scale inside the matrix', () {
      // A unit box scaled 6x through the matrix reaches 3 units from its
      // anchor; the cull rect only contains its far right end.
      final right = rig.projectWorldPoint(2.5, -2.5, 0).dx;
      final renderer = BatchMeshRenderer3D(
        cullScreenBounds: Rect.fromLTRB(right - 5, -1000, right + 1000, 1000),
      )..beginBatch();
      renderer.enqueueMesh(
        Mesh3D.box(),
        camera: rig,
        worldX: 0,
        worldY: 0,
        rotationMatrix3: Float32List.fromList(_diag(6, 6, 6)),
      );
      expect(renderer.activeEnqueuedMeshes, 1);
    });
  });

  group('visual mutation notifications', () {
    int delta(void Function() change) {
      final before = Game.visualMutationCount;
      change();
      return Game.visualMutationCount - before;
    }

    test('Node3D notifies on every real transform or appearance change', () {
      final node = Node3D();
      expect(delta(() => node.localX = 3.0), 1);
      expect(delta(() => node.localY = -1.0), 1);
      expect(delta(() => node.localZ = 0.5), 1);
      expect(delta(() => node.localYawRad = 1.0), 1);
      expect(delta(() => node.localPitchRad = 0.2), 1);
      expect(delta(() => node.localRollRad = -0.2), 1);
      expect(delta(() => node.localScaleX = 2.0), 1);
      expect(delta(() => node.localScaleY = 2.0), 1);
      expect(delta(() => node.localScaleZ = 2.0), 1);
      expect(delta(() => node.tint = const Color(0xFF112233)), 1);
      expect(delta(() => node.opacity = 0.5), 1);
      expect(delta(() => node.emissive = 0.3), 1);
      expect(delta(() => node.visible = false), 1);
      expect(delta(() => node.sortOrder = 2), 1);
      expect(delta(() => node.depthBias = 0.1), 1);
      expect(delta(() => node.castGroundShadow = true), 1);
      expect(delta(() => node.mesh = Mesh3D.plane()), 1);
      expect(delta(() => node.material = _flat), 1);
      expect(
        delta(() => node.uvRectPx = const Rect.fromLTWH(0, 0, 8, 8)),
        1,
      );
      expect(delta(() => node.setLocalQuaternion(0, 0, 1, 1)), 1);
      expect(delta(node.clearLocalQuaternion), 1);
    });

    test('Node3D stays quiet when a value is set to what it already is', () {
      final node = Node3D(localX: 3.0, localYawRad: 1.0, opacity: 0.5)
        ..setLocalQuaternion(0, 0, 0, 1);
      expect(delta(() => node.localX = 3.0), 0);
      expect(delta(() => node.localYawRad = 1.0), 0);
      expect(delta(() => node.opacity = 0.5), 0);
      expect(delta(() => node.visible = true), 0);
      expect(delta(() => node.setLocalQuaternion(0, 0, 0, 1)), 0);
      expect(delta(node.updateWorldTransforms), 0);
    });

    test('CameraRig3D notifies when focus, zoom or an angle delta changes', () {
      final rig = CameraRig3D()..update(camX: 10, camY: 20, zoom: 1);
      expect(delta(() => rig.update(camX: 10, camY: 20, zoom: 1)), 0);
      expect(delta(() => rig.update(camX: 11, camY: 20, zoom: 1)), 1);
      expect(delta(() => rig.update(camX: 11, camY: 21, zoom: 1)), 1);
      expect(delta(() => rig.update(camX: 11, camY: 21, zoom: 1.5)), 1);

      final version = rig.basisVersion;
      expect(
        delta(
          () => rig.update(camX: 11, camY: 21, zoom: 1.5, orbitYawDelta: 0.1),
        ),
        1,
      );
      expect(rig.basisVersion, version + 1);
      expect(
        delta(
          () => rig.update(
            camX: 11,
            camY: 21,
            zoom: 1.5,
            orbitYawDelta: 0.1,
            pitchDelta: -0.1,
          ),
        ),
        1,
      );
      expect(rig.basisVersion, version + 2);

      expect(delta(() => rig.camWorldX = 11), 0);
      expect(delta(() => rig.camWorldX = 12), 1);
      expect(delta(() => rig.camZoom = 2), 1);
      expect(delta(() => rig.cameraDistance = 30), 1);
      expect(delta(() => rig.fovYRad = 1.0), 1);
      expect(
        delta(() => rig.projectionMode = CameraProjectionMode3D.perspective),
        1,
      );
    });

    test('CameraRig3D angle delta setters take effect and are clamped', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final restRightX = rig.rightX;
      final version = rig.basisVersion;

      expect(delta(() => rig.orbitYawDeltaRad = 0.2), 1);
      expect(rig.basisVersion, version + 1);
      expect(rig.rightX, closeTo(math.sin(math.pi / 4 + 0.2), 1e-9));
      expect(rig.rightX, isNot(closeTo(restRightX, 1e-3)));

      rig.orbitYawDeltaRad = 5.0;
      expect(rig.orbitYawDeltaRad, CameraRig3D.maxOrbitYawDeltaRad);
      rig.pitchDeltaRad = -5.0;
      expect(rig.pitchDeltaRad, CameraRig3D.minPitchDeltaRad);
      rig.pitchDeltaRad = 5.0;
      expect(rig.pitchDeltaRad, CameraRig3D.maxPitchDeltaRad);

      // `update` clamps the same way.
      rig.update(camX: 0, camY: 0, zoom: 1, orbitYawDelta: -9, pitchDelta: 9);
      expect(rig.orbitYawDeltaRad, -CameraRig3D.maxOrbitYawDeltaRad);
      expect(rig.pitchDeltaRad, CameraRig3D.maxPitchDeltaRad);
    });

    test('DirectionalLight3D notifies when a setting really changes', () {
      final light = DirectionalLight3D();
      final signature = light.computeSignature();
      expect(delta(() => light.setDirection(1, 0, 1)), 1);
      // The same direction at another length is not a change.
      expect(delta(() => light.setDirection(2, 0, 2)), 0);
      expect(delta(() => light.setDirection(0, 0, 0)), 0);
      expect(delta(() => light.sunColor = const Color(0xFFFF8040)), 1);
      expect(delta(() => light.sunColor = const Color(0xFFFF8040)), 0);
      expect(delta(() => light.skyColor = const Color(0xFF102030)), 1);
      expect(delta(() => light.groundColor = const Color(0xFF302010)), 1);
      expect(delta(() => light.ambientIntensity = 0.5), 1);
      expect(delta(() => light.diffuseIntensity = 0.5), 1);
      expect(delta(() => light.rimIntensity = 0.5), 1);
      expect(delta(() => light.rimIntensity = 0.5), 0);
      expect(light.computeSignature(), isNot(signature));
      expect(light.dirX, closeTo(math.sqrt1_2, 1e-9));
    });
  });
}
