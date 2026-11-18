import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas, Color;

import 'package:flame/canvas3d.dart' as c3d;
import 'package:flame/components.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart' as f3d;
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';

/// {@template canvas_3d_fallback_component}
/// Cross-platform software-projected Impeller 2D Canvas fallback bridge for a
/// [World3D] using `package:flame/canvas3d.dart` (`BatchMeshRenderer3D`).
///
/// Use this component on platforms or environments where Flutter GPU / WebGPU
/// is unavailable (`!GpuBackend.isAvailable`, such as Windows, Linux, or legacy
/// OpenGL ES devices without `FLTEnableFlutterGPU`), allowing [MeshComponent],
/// [InstancedGroup3D], [ModelComponent], and [LightComponent] scenes in a
/// [World3D] to render cleanly via `Canvas.drawVertices`.
/// {@endtemplate}
class Canvas3DFallbackComponent({
  required final World3D world,
  c3d.CameraRig3D? cameraRig,
  var bool drawShadows = false,
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

  /// Projection camera rig driving the `canvas3d` software projection.
  final c3d.CameraRig3D cameraRig =
      cameraRig ??
      c3d.CameraRig3D(
        projectionMode: c3d.CameraProjectionMode3D.perspective,
      );

  final c3d.BatchMeshRenderer3D _batcher = c3d.BatchMeshRenderer3D();
  final Expando<List<c3d.Mesh3D>> _convertedMeshes = Expando();
  final Float32List _rotScratch = Float32List(9);

  int _lastTrianglesSubmitted = 0;

  /// Total triangles converted and submitted in the most recent [render] pass.
  int get lastTrianglesSubmitted => _lastTrianglesSubmitted;

  List<c3d.Mesh3D> _meshesFor(Mesh mesh) {
    final cached = _convertedMeshes[mesh];
    if (cached != null) {
      return cached;
    }
    final built = <c3d.Mesh3D>[];
    for (final surface in mesh.surfaces) {
      final stride = surface.layout.strideInFloats;
      final vCount = surface.vertexCount;
      if (vCount == 0 || vCount > c3d.Mesh3D.maxVertexCount) {
        continue;
      }
      final vData = surface.vertexData;
      final posOffset = surface.layout.offsetOf(VertexLayout.positionAttribute);
      final normOffset = surface.layout.offsetOf('vertexNormal');
      final colOffset = surface.layout.offsetOf('vertexColor');
      if (posOffset == null) {
        continue;
      }

      final positions = Float32List(vCount * 3);
      final normals = Float32List(vCount * 3);
      final colors = Int32List(vCount);
      final baseTint = switch (surface.material) {
        final SpatialMaterial m => m.albedoColor,
        final StylizedMaterial m => m.albedoColor,
        final UnlitMaterial m => m.albedoColor,
        _ => const Color(0xFFFFFFFF),
      };

      for (var i = 0; i < vCount; i++) {
        final b = i * stride;
        positions[i * 3] = vData[b + posOffset];
        positions[i * 3 + 1] = vData[b + posOffset + 1];
        positions[i * 3 + 2] = vData[b + posOffset + 2];

        if (normOffset != null) {
          normals[i * 3] = vData[b + normOffset];
          normals[i * 3 + 1] = vData[b + normOffset + 1];
          normals[i * 3 + 2] = vData[b + normOffset + 2];
        } else {
          normals[i * 3 + 2] = 1.0;
        }

        var cr = baseTint.r;
        var cg = baseTint.g;
        var cb = baseTint.b;
        var ca = baseTint.a;
        if (colOffset != null) {
          cr *= vData[b + colOffset];
          cg *= vData[b + colOffset + 1];
          cb *= vData[b + colOffset + 2];
          ca *= vData[b + colOffset + 3];
        }
        colors[i] =
            ((ca.clamp(0.0, 1.0) * 255).round() << 24) |
            ((cr.clamp(0.0, 1.0) * 255).round() << 16) |
            ((cg.clamp(0.0, 1.0) * 255).round() << 8) |
            (cb.clamp(0.0, 1.0) * 255).round();
      }

      final srcIdx = surface.indices;
      final triIndices = srcIdx is Uint16List
          ? srcIdx
          : Uint16List.fromList(srcIdx);

      built.add(
        c3d.Mesh3D(
          positions: positions,
          normals: normals,
          indices: triIndices,
          vertexColors: colors,
        ),
      );
    }
    _convertedMeshes[mesh] = built;
    return built;
  }

  void _syncLighting() {
    for (final child in world.children) {
      if (child is LightComponent) {
        final src = child.source;
        if (src is DirectionalLight) {
          final d = src.direction ?? f3d.Vector3(-0.4, -0.4, -0.8);
          _batcher.light.setDirection(-d.x, -d.y, -d.z);
          break;
        }
      }
    }
  }

  void _enqueueMeshWithMatrix(Mesh mesh, f3d.Matrix4 m) {
    final s = m.storage;
    final sx = math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    final sy = math.sqrt(s[4] * s[4] + s[5] * s[5] + s[6] * s[6]);
    final sz = math.sqrt(s[8] * s[8] + s[9] * s[9] + s[10] * s[10]);
    final invSx = sx > 1e-6 ? 1.0 / sx : 1.0;
    final invSy = sy > 1e-6 ? 1.0 / sy : 1.0;
    final invSz = sz > 1e-6 ? 1.0 / sz : 1.0;

    // Row-major unit 3x3 rotation matrix expected by `enqueueMesh`.
    _rotScratch[0] = s[0] * invSx;
    _rotScratch[1] = s[4] * invSy;
    _rotScratch[2] = s[8] * invSz;
    _rotScratch[3] = s[1] * invSx;
    _rotScratch[4] = s[5] * invSy;
    _rotScratch[5] = s[9] * invSz;
    _rotScratch[6] = s[2] * invSx;
    _rotScratch[7] = s[6] * invSy;
    _rotScratch[8] = s[10] * invSz;

    for (final cMesh in _meshesFor(mesh)) {
      _lastTrianglesSubmitted += cMesh.indices.length ~/ 3;
      _batcher.enqueueMesh(
        cMesh,
        camera: cameraRig,
        worldX: s[12],
        worldY: s[13],
        worldZ: s[14],
        scaleX: sx,
        scaleY: sy,
        scaleZ: sz,
        rotationMatrix3: _rotScratch,
        castGroundShadow: drawShadows,
      );
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    _syncLighting();
    _batcher.beginBatch();
    _lastTrianglesSubmitted = 0;

    void visit(Component comp) {
      if (comp is MeshComponent) {
        _enqueueMeshWithMatrix(comp.mesh, comp.worldTransformMatrix);
      } else if (comp is ModelComponent) {
        final pose = comp.evaluatePose();
        final wm = comp.worldTransformMatrix;
        final combined = f3d.Matrix4.identity();
        for (final node in pose.orderedNodes) {
          final mesh = node.node.mesh;
          if (mesh != null) {
            combined
              ..setFrom(wm)
              ..multiply(node.combinedTransform);
            _enqueueMeshWithMatrix(mesh, combined);
          }
        }
      } else if (comp is InstancedGroup3D) {
        final wm = comp.worldTransformMatrix;
        final instMat = f3d.Matrix4.identity();
        final combined = f3d.Matrix4.identity();
        for (var i = 0; i < comp.length; i++) {
          comp.instanceTransform(i, out: instMat);
          combined
            ..setFrom(wm)
            ..multiply(instMat);
          _enqueueMeshWithMatrix(comp.mesh, combined);
        }
      }
      for (final child in comp.children) {
        visit(child);
      }
    }

    for (final child in world.children) {
      visit(child);
    }

    if (drawShadows) {
      _batcher.flushShadows(canvas);
    }
    _batcher.flushGeometry(canvas);
  }
}
