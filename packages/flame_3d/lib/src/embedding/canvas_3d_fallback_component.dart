import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show BlendMode, Canvas, Color, Paint, VertexMode, Vertices;

import 'package:flame/components.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart' as f3d;
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';

/// {@template canvas_3d_fallback_component}
/// A CPU fallback that draws a [World3D] on a 2D [Canvas] with one
/// [Canvas.drawVertices] call, for platforms where `GpuBackend.isAvailable`
/// is `false` (devices and processes without Flutter GPU).
///
/// It draws the [MeshComponent]s, the instances of [InstancedGroup3D]s and
/// the nodes of [ModelComponent]s that a pass of [camera] would draw (visible,
/// and sharing a bit of their `cameraMask` with the camera's), as flat
/// triangles sorted back to front by their average depth. Each vertex gets
/// its material's base color (`albedoColor` of [SpatialMaterial],
/// [StylizedMaterial] or [UnlitMaterial], white for other materials) times
/// its vertex color times the component's color, shaded by the last
/// directional light and the last ambient light of the world. Surfaces of
/// [ShadowCatcherMaterial] and [OutlineMaterial], which only make sense with
/// GPU shadows and outlines, are skipped.
///
/// It does not draw textures, shadows, fog, specular light, light colors,
/// point, spot or hemisphere lights, particles, billboards, text, decals, the
/// skybox, [LodMeshComponent]s, custom [Object3D]s, skinning or morph
/// targets, and has no depth buffer: intersecting triangles are sorted as
/// wholes and a triangle that crosses the near plane is dropped.
/// {@endtemplate}
class Canvas3DFallbackComponent({
  required final World3D world,
  CameraComponent3D? camera,
  var bool cullBackFaces = true,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
}) extends PositionComponent {
  /// {@macro canvas_3d_fallback_component}
  this {
    if (!world.isMounted) {
      add(world);
    }
  }

  /// Camera driving the 3D-to-2D software projection.
  final CameraComponent3D camera =
      camera ??
      CameraComponent3D(
        position: f3d.Vector3(6, 5, 6),
        target: f3d.Vector3(0, 0.5, 0),
        up: f3d.Vector3(0, 1, 0),
        fovY: 50,
      );

  final f3d.Matrix4 _viewProj = f3d.Matrix4.identity();
  final f3d.Matrix4 _projection = f3d.Matrix4.zero();
  final f3d.Matrix4 _scratchModel = f3d.Matrix4.identity();
  final f3d.Matrix4 _scratchInstance = f3d.Matrix4.identity();
  final Float64List _projectionValues = Float64List(16);
  final Paint _paint = Paint();

  Float32List _triPositions = Float32List(512 * 6);
  Int32List _triColors = Int32List(512 * 3);
  Float32List _triDepths = Float32List(512);
  Int32List _triOrder = Int32List(512);
  Float32List _sortedPositions = Float32List(512 * 6);
  Int32List _sortedColors = Int32List(512 * 3);
  int _triCount = 0;

  // The light of the frame, see [_scanLights].
  double _sunX = 0;
  double _sunY = 0;
  double _sunZ = 0;
  double _sunIntensity = 0;
  double _ambient = 0;
  double _halfWidth = 0;
  double _halfHeight = 0;

  int _lastTrianglesSubmitted = 0;

  /// Total visible triangles projected and submitted in the most recent
  /// [render] pass.
  int get lastTrianglesSubmitted => _lastTrianglesSubmitted;

  void _ensureTriangleCapacity(int neededTris) {
    if (neededTris <= _triDepths.length) {
      return;
    }
    var nextCap = _triDepths.length;
    while (nextCap < neededTris) {
      nextCap *= 2;
    }
    final nextPos = Float32List(nextCap * 6)
      ..setRange(0, _triPositions.length, _triPositions);
    final nextCol = Int32List(nextCap * 3)
      ..setRange(0, _triColors.length, _triColors);
    final nextDep = Float32List(nextCap)
      ..setRange(0, _triDepths.length, _triDepths);
    _triPositions = nextPos;
    _triColors = nextCol;
    _triDepths = nextDep;
    _triOrder = Int32List(nextCap);
    _sortedPositions = Float32List(nextCap * 6);
    _sortedColors = Int32List(nextCap * 3);
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final vpW = size.x > 0 ? size.x : 320.0;
    final vpH = size.y > 0 ? size.y : 200.0;
    _halfWidth = vpW * 0.5;
    _halfHeight = vpH * 0.5;
    _writeViewProjection(vpW / vpH);
    _scanLights();

    _triCount = 0;
    _visit(world);
    final triCount = _triCount;
    _lastTrianglesSubmitted = triCount;
    if (triCount == 0) {
      return;
    }

    // Back-to-front painter's sort by average clip depth.
    final order = _triOrder;
    for (var i = 0; i < triCount; i++) {
      order[i] = i;
    }
    _sortBackToFront(order, _triDepths, triCount);

    final sortedPos = _sortedPositions;
    final sortedCol = _sortedColors;
    for (var i = 0; i < triCount; i++) {
      final src = order[i];
      final sp = src * 6;
      final dp = i * 6;
      sortedPos
        ..[dp] = _triPositions[sp]
        ..[dp + 1] = _triPositions[sp + 1]
        ..[dp + 2] = _triPositions[sp + 2]
        ..[dp + 3] = _triPositions[sp + 3]
        ..[dp + 4] = _triPositions[sp + 4]
        ..[dp + 5] = _triPositions[sp + 5];
      final sc = src * 3;
      final dc = i * 3;
      sortedCol
        ..[dc] = _triColors[sc]
        ..[dc + 1] = _triColors[sc + 1]
        ..[dc + 2] = _triColors[sc + 2];
    }

    final vertices = Vertices.raw(
      VertexMode.triangles,
      Float32List.sublistView(sortedPos, 0, triCount * 6),
      colors: Int32List.sublistView(sortedCol, 0, triCount * 3),
    );
    canvas.drawVertices(vertices, BlendMode.dst, _paint);
    vertices.dispose();
  }

  /// Writes the camera's view and a projection for [aspectRatio] (the
  /// camera's custom one when it has one) into [_viewProj], with the clip
  /// depth of [CameraComponent3D]: 0 on the near plane, 1 on the far one.
  void _writeViewProjection(double aspectRatio) {
    final camera = this.camera;
    final custom = camera.customProjectionMatrix;
    if (custom != null) {
      _projection.setFrom(custom);
    } else {
      final values = _projectionValues;
      if (camera.projection == CameraProjection.orthographic) {
        final top = (camera.orthographicHeight ?? camera.fovY) / 2;
        final right = top * aspectRatio;
        writeOrthographic(
          values,
          -right,
          right,
          -top,
          top,
          camera.near,
          camera.far,
        );
      } else {
        writePerspective(
          values,
          camera.fovY * f3d.degrees2Radians,
          aspectRatio,
          camera.near,
          camera.far,
        );
      }
      final storage = _projection.storage;
      for (var i = 0; i < 16; i++) {
        storage[i] = values[i];
      }
    }
    _viewProj
      ..setFrom(_projection)
      ..multiply(camera.viewMatrix);
  }

  /// Picks the last directional light and the last ambient light of [world]
  /// (a default sun and ambient without them).
  void _scanLights() {
    _sunX = 0.4;
    _sunY = 0.8;
    _sunZ = 0.45;
    _sunIntensity = 0.85;
    _ambient = 0.28;
    _scanLightsIn(world);
    final sunLen = math.sqrt(_sunX * _sunX + _sunY * _sunY + _sunZ * _sunZ);
    if (sunLen > 1e-9) {
      _sunX /= sunLen;
      _sunY /= sunLen;
      _sunZ /= sunLen;
    }
  }

  void _scanLightsIn(Component node) {
    for (final child in node.children) {
      if (child is LightComponent) {
        final src = child.source;
        if (src is DirectionalLight) {
          // The light's direction follows its world transform.
          child.worldTransformMatrix;
          final d = child.light.direction(_lightDirection);
          _sunX = -d.x;
          _sunY = -d.y;
          _sunZ = -d.z;
          _sunIntensity = (src.intensity * 0.45).clamp(0.1, 1.5);
        } else if (src is AmbientLight) {
          _ambient = src.intensity.clamp(0.05, 1.0);
        }
      }
      _scanLightsIn(child);
    }
  }

  final f3d.Vector3 _lightDirection = f3d.Vector3.zero();

  /// Submits what a pass of [camera] would draw of [comp] and its subtree.
  void _visit(Component comp) {
    if (comp is Component3D) {
      if (!comp.visible || (comp.cameraMask & camera.cameraMask) == 0) {
        return;
      }
      if (comp is MeshComponent) {
        _submitMesh(comp.mesh, comp.worldTransformMatrix, comp.color);
      } else if (comp is InstancedGroup3D) {
        final groupWorld = comp.worldTransformMatrix;
        for (var i = 0; i < comp.length; i++) {
          _scratchModel
            ..setFrom(groupWorld)
            ..multiply(comp.instanceTransform(i, out: _scratchInstance));
          _submitMesh(comp.mesh, _scratchModel, const Color(0xFFFFFFFF));
        }
      } else if (comp is ModelComponent) {
        final workspace = comp.evaluatePose();
        final modelWorld = comp.worldTransformMatrix;
        for (final posedNode in workspace.orderedNodes) {
          final mesh = posedNode.node.mesh;
          if (mesh != null) {
            _scratchModel
              ..setFrom(modelWorld)
              ..multiply(posedNode.combinedTransform);
            _submitMesh(mesh, _scratchModel, comp.color);
          }
        }
      }
    }
    for (final child in comp.children) {
      _visit(child);
    }
  }

  void _submitMesh(Mesh mesh, f3d.Matrix4 modelMatrix, Color instanceTint) {
    final m = modelMatrix.storage;
    final vp = _viewProj.storage;
    final halfW = _halfWidth;
    final halfH = _halfHeight;
    final sunX = _sunX;
    final sunY = _sunY;
    final sunZ = _sunZ;
    final sunIntensity = _sunIntensity;
    final ambient = _ambient;

    for (final surface in mesh.surfaces) {
      final material = surface.material;
      if (material is ShadowCatcherMaterial || material is OutlineMaterial) {
        continue;
      }
      final stride = surface.layout.strideInFloats;
      final vCount = surface.vertexCount;
      final posOff = surface.layout.offsetOf(VertexLayout.positionAttribute);
      if (vCount == 0 || posOff == null) {
        continue;
      }
      final normOff = surface.layout.offsetOf('vertexNormal');
      final colOff = surface.layout.offsetOf('vertexColor');
      final vData = surface.vertexData;
      final indices = surface.indices;
      final baseTint = switch (material) {
        final SpatialMaterial mat => mat.albedoColor,
        final StylizedMaterial mat => mat.albedoColor,
        final UnlitMaterial mat => mat.albedoColor,
        _ => const Color(0xFFFFFFFF),
      };
      final unlit = material is UnlitMaterial;

      final surfTris = indices.length ~/ 3;
      _ensureTriangleCapacity(_triCount + surfTris);

      for (var t = 0; t < surfTris; t++) {
        final i0 = indices[t * 3];
        final i1 = indices[t * 3 + 1];
        final i2 = indices[t * 3 + 2];

        double sx0 = 0;
        double sy0 = 0;
        double sx1 = 0;
        double sy1 = 0;
        double sx2 = 0;
        double sy2 = 0;
        double zSum = 0;
        var clipped = false;
        var c0 = 0;
        var c1 = 0;
        var c2 = 0;

        for (var corner = 0; corner < 3; corner++) {
          final vi = corner == 0
              ? i0
              : corner == 1
              ? i1
              : i2;
          final b = vi * stride;
          final lx = vData[b + posOff];
          final ly = vData[b + posOff + 1];
          final lz = vData[b + posOff + 2];

          final wx = m[0] * lx + m[4] * ly + m[8] * lz + m[12];
          final wy = m[1] * lx + m[5] * ly + m[9] * lz + m[13];
          final wz = m[2] * lx + m[6] * ly + m[10] * lz + m[14];

          final cx = vp[0] * wx + vp[4] * wy + vp[8] * wz + vp[12];
          final cy = vp[1] * wx + vp[5] * wy + vp[9] * wz + vp[13];
          final cz = vp[2] * wx + vp[6] * wy + vp[10] * wz + vp[14];
          final cw = vp[3] * wx + vp[7] * wy + vp[11] * wz + vp[15];

          if (cw <= 1e-6) {
            clipped = true;
            break;
          }
          final invW = 1.0 / cw;
          final ndcX = cx * invW;
          final ndcY = cy * invW;
          final ndcZ = cz * invW;
          // Outside the depth range between the near and the far plane.
          if (ndcZ < 0.0 || ndcZ > 1.0) {
            clipped = true;
            break;
          }
          final px = halfW + ndcX * halfW;
          final py = halfH - ndcY * halfH;
          zSum += ndcZ;

          var cr = baseTint.r * instanceTint.r;
          var cg = baseTint.g * instanceTint.g;
          var cb = baseTint.b * instanceTint.b;
          var ca = baseTint.a * instanceTint.a;
          if (colOff != null) {
            cr *= vData[b + colOff];
            cg *= vData[b + colOff + 1];
            cb *= vData[b + colOff + 2];
            ca *= vData[b + colOff + 3];
          }

          var shade = 1.0;
          if (!unlit && normOff != null) {
            final nx = vData[b + normOff];
            final ny = vData[b + normOff + 1];
            final nz = vData[b + normOff + 2];
            var wnx = m[0] * nx + m[4] * ny + m[8] * nz;
            var wny = m[1] * nx + m[5] * ny + m[9] * nz;
            var wnz = m[2] * nx + m[6] * ny + m[10] * nz;
            final nLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
            if (nLen > 1e-9) {
              wnx /= nLen;
              wny /= nLen;
              wnz /= nLen;
            }
            final ndotl = math.max(0.0, wnx * sunX + wny * sunY + wnz * sunZ);
            shade = (ambient + ndotl * sunIntensity).clamp(0.0, 1.35);
          }

          final argb =
              ((ca.clamp(0.0, 1.0) * 255).round() << 24) |
              (((cr * shade).clamp(0.0, 1.0) * 255).round() << 16) |
              (((cg * shade).clamp(0.0, 1.0) * 255).round() << 8) |
              ((cb * shade).clamp(0.0, 1.0) * 255).round();

          if (corner == 0) {
            sx0 = px;
            sy0 = py;
            c0 = argb;
          } else if (corner == 1) {
            sx1 = px;
            sy1 = py;
            c1 = argb;
          } else {
            sx2 = px;
            sy2 = py;
            c2 = argb;
          }
        }

        if (clipped) {
          continue;
        }

        if (cullBackFaces) {
          // Screen Y points downward, so CCW in clip space has negative
          // signed area `(sx1 - sx0)*(sy2 - sy0) - (sy1 - sy0)*(sx2 - sx0)`.
          final area2 = (sx1 - sx0) * (sy2 - sy0) - (sy1 - sy0) * (sx2 - sx0);
          if (area2 >= 0) {
            continue;
          }
        }

        final triCount = _triCount;
        final baseP = triCount * 6;
        _triPositions
          ..[baseP] = sx0
          ..[baseP + 1] = sy0
          ..[baseP + 2] = sx1
          ..[baseP + 3] = sy1
          ..[baseP + 4] = sx2
          ..[baseP + 5] = sy2;
        final baseC = triCount * 3;
        _triColors
          ..[baseC] = c0
          ..[baseC + 1] = c1
          ..[baseC + 2] = c2;
        _triDepths[triCount] = zSum;
        _triCount = triCount + 1;
      }
    }
  }

  /// Sorts the first [count] entries of [order] by decreasing [depths] in
  /// place (heapsort: no allocation, `O(n log n)`).
  static void _sortBackToFront(Int32List order, Float32List depths, int count) {
    // A min-heap on depth keeps the nearest at the root; moving it to the end
    // leaves the farthest first.
    for (var start = count ~/ 2 - 1; start >= 0; start--) {
      _siftDown(order, depths, start, count);
    }
    for (var end = count - 1; end > 0; end--) {
      final tmp = order[0];
      order[0] = order[end];
      order[end] = tmp;
      _siftDown(order, depths, 0, end);
    }
  }

  static void _siftDown(
    Int32List order,
    Float32List depths,
    int start,
    int end,
  ) {
    var root = start;
    while (true) {
      final child = 2 * root + 1;
      if (child >= end) {
        return;
      }
      var swap = root;
      if (depths[order[child]] < depths[order[swap]]) {
        swap = child;
      }
      if (child + 1 < end && depths[order[child + 1]] < depths[order[swap]]) {
        swap = child + 1;
      }
      if (swap == root) {
        return;
      }
      final tmp = order[root];
      order[root] = order[swap];
      order[swap] = tmp;
      root = swap;
    }
  }
}
