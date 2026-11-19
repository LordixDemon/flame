import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// Draws `N` depth-buffered HD-2D sprites, standees, foliage cards, or world
/// icons in a single instanced GPU draw call using [BillboardMaterial3D].
///
/// Billboard positions are in the batch's local space: the batch's transform
/// (and its parents') places them, and its largest axis scale scales their
/// sizes. Each billboard faces the camera on its own.
class BillboardBatch3D({
  BillboardMaterial3D? material,
  int initialCapacity = 32,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.cameraMask,
}) extends Object3D {
  this : super(castsShadows: false) {
    _capacity = math.max(1, initialCapacity);
    _instances = Float32List(_capacity * _stride);
  }

  final BillboardMaterial3D material = material ?? BillboardMaterial3D();

  static const int _stride = VertexLayout.instanceStrideInFloats;

  static final Surface _unitQuad = Surface.fromBuffers(
    vertices: Float32List.fromList(const [
      -0.5, -0.5, 0.0, 0.0, 1.0, //
      0.5, -0.5, 0.0, 1.0, 1.0, //
      0.5, 0.5, 0.0, 1.0, 0.0, //
      -0.5, 0.5, 0.0, 0.0, 0.0, //
    ]),
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    layout: VertexLayout(const [
      VertexAttribute(VertexLayout.positionAttribute, 3),
      VertexAttribute('vertexTexCoord', 2),
    ]),
  );

  static final Vector3 _defaultUp = Vector3(0, 1, 0);
  static final Vector3 _defaultRight = Vector3(1, 0, 0);

  int _capacity = 32;
  int _length = 0;
  late Float32List _instances;
  final Aabb3 _localAabb = Aabb3();
  bool _boundsDirty = true;

  // The instances placed in world space by the transform they were last
  // drawn with, rebuilt when the instances or the transform change.
  Float32List? _worldInstances;
  bool _worldInstancesDirty = true;
  final Float64List _worldInstancesTransform = Float64List(16);

  int get length => _length;
  bool get isEmpty => _length == 0;

  void clear() {
    if (_length == 0) {
      return;
    }
    _length = 0;
    _boundsDirty = true;
    _worldInstancesDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  /// Appends a billboard / standee and returns its slot index.
  ///
  /// [position] is in the batch's local space. [anchorY] controls the
  /// vertical pivot (`0.0` = centered, `-0.5` = grounded at the bottom edge
  /// of the sprite) and [anchorX] the horizontal one (`0.0` = centered,
  /// `-0.5` = the left edge at [position]), both in sprite sizes; values
  /// beyond `±0.5` place the sprite away from [position] along the camera
  /// plane (`MsdfTextBatch3D` lays out the glyphs of a string this way).
  /// [rollRadians] turns the sprite around its pivot, in the camera plane.
  ///
  /// A [BillboardOrientation3D.fixed] sprite does not face the camera: it
  /// lies in the plane of [upAxis] and [rightAxis] (made perpendicular to
  /// [upAxis]) and ignores [tiltRadians].
  int addBillboard({
    required Vector3 position,
    required double width,
    required double height,
    BillboardOrientation3D orientation = BillboardOrientation3D.cylindrical,
    Vector3? upAxis,
    double anchorY = -0.5,
    double anchorX = 0.0,
    Vector3? rightAxis,
    double tiltRadians = 0.0,
    double rollRadians = 0.0,
    Rect uvRect = const Rect.fromLTWH(0, 0, 1, 1),
    Color color = const Color(0xFFFFFFFF),
    double emissiveBoost = 0.0,
    double unlit = 0.0,
    double fade = 0.0,
  }) {
    final idx = _length;
    if (idx == _capacity) {
      final next = _capacity * 2;
      _instances = Float32List(next * _stride)..setAll(0, _instances);
      _capacity = next;
    }
    _length++;
    _writeSlot(
      idx,
      position: position,
      width: width,
      height: height,
      orientation: orientation,
      upAxis: upAxis ?? _defaultUp,
      rightAxis: rightAxis ?? _defaultRight,
      anchorY: anchorY,
      anchorX: anchorX,
      tiltRadians: tiltRadians,
      rollRadians: rollRadians,
      uvRect: uvRect,
      color: color,
      emissiveBoost: emissiveBoost,
      unlit: unlit,
      fade: fade,
    );
    _boundsDirty = true;
    _worldInstancesDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
    return idx;
  }

  /// Updates an existing billboard at [index] in place, see [addBillboard].
  void setBillboard(
    int index, {
    required Vector3 position,
    required double width,
    required double height,
    BillboardOrientation3D orientation = BillboardOrientation3D.cylindrical,
    Vector3? upAxis,
    double anchorY = -0.5,
    double anchorX = 0.0,
    Vector3? rightAxis,
    double tiltRadians = 0.0,
    double rollRadians = 0.0,
    Rect uvRect = const Rect.fromLTWH(0, 0, 1, 1),
    Color color = const Color(0xFFFFFFFF),
    double emissiveBoost = 0.0,
    double unlit = 0.0,
    double fade = 0.0,
  }) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    _writeSlot(
      index,
      position: position,
      width: width,
      height: height,
      orientation: orientation,
      upAxis: upAxis ?? _defaultUp,
      rightAxis: rightAxis ?? _defaultRight,
      anchorY: anchorY,
      anchorX: anchorX,
      tiltRadians: tiltRadians,
      rollRadians: rollRadians,
      uvRect: uvRect,
      color: color,
      emissiveBoost: emissiveBoost,
      unlit: unlit,
      fade: fade,
    );
    _boundsDirty = true;
    _worldInstancesDirty = true;
    markAabbDirty();
    worldOrNull?.markSceneDirty(shadows: false);
  }

  void _writeSlot(
    int index, {
    required Vector3 position,
    required double width,
    required double height,
    required BillboardOrientation3D orientation,
    required Vector3 upAxis,
    required Vector3 rightAxis,
    required double anchorY,
    required double anchorX,
    required double tiltRadians,
    required double rollRadians,
    required Rect uvRect,
    required Color color,
    required double emissiveBoost,
    required double unlit,
    required double fade,
  }) {
    final b = index * _stride;
    // A fixed sprite keeps its right direction as an angle about its up
    // axis in the slot of the tilt, which it has no use for.
    final tiltOrRight = orientation == BillboardOrientation3D.fixed
        ? _fixedRightAngle(
            upAxis.x,
            upAxis.y,
            upAxis.z,
            rightAxis.x,
            rightAxis.y,
            rightAxis.z,
          )
        : tiltRadians;
    _instances
      ..[b] = position.x
      ..[b + 1] = position.y
      ..[b + 2] = position.z
      ..[b + 3] = width
      ..[b + 4] = upAxis.x
      ..[b + 5] = upAxis.y
      ..[b + 6] = upAxis.z
      ..[b + 7] = height
      ..[b + 8] = uvRect.left
      ..[b + 9] = uvRect.top
      ..[b + 10] = uvRect.width
      ..[b + 11] = uvRect.height
      ..[b + 12] = anchorY
      ..[b + 13] = tiltOrRight
      ..[b + 14] = rollRadians
      ..[b + 15] = orientation.index.toDouble()
      ..[b + 16] = color.r
      ..[b + 17] = color.g
      ..[b + 18] = color.b
      ..[b + 19] = color.a
      ..[b + 20] = emissiveBoost
      ..[b + 21] = unlit
      ..[b + 22] = fade
      ..[b + 23] = anchorX;
  }

  // How much larger than its smallest axis scale the largest is, for the
  // transform the bounds were computed with.
  double _boundsAnisotropy = 1;

  @override
  Aabb3? computeLocalAabb() {
    if (_length == 0) {
      return null;
    }
    // Sizes are scaled by the largest axis scale of the transform, while the
    // local box shrinks along the smallest: grow it by their ratio so that
    // it still holds the billboards.
    final m = worldTransformMatrix.storage;
    double axis(int c) => math.sqrt(
      m[c] * m[c] + m[c + 1] * m[c + 1] + m[c + 2] * m[c + 2],
    );
    final largest = math.max(axis(0), math.max(axis(4), axis(8)));
    final smallest = math.min(axis(0), math.min(axis(4), axis(8)));
    final anisotropy = smallest > 1e-12 ? largest / smallest : 1.0;
    if (anisotropy != _boundsAnisotropy) {
      _boundsAnisotropy = anisotropy;
      _boundsDirty = true;
    }
    if (_boundsDirty) {
      _boundsDirty = false;
      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      for (var i = 0; i < _length; i++) {
        final b = i * _stride;
        final cx = _instances[b];
        final cy = _instances[b + 1];
        final cz = _instances[b + 2];
        // The farthest corner from the center, whatever the camera, roll
        // and tilt: corners are (x - anchorX) * width to the side and
        // (y - anchorY) * height up, with x and y in [-0.5, 0.5].
        final rx = (_instances[b + 23].abs() + 0.5) * _instances[b + 3];
        final ry = (_instances[b + 12].abs() + 0.5) * _instances[b + 7];
        final r = math.sqrt(rx * rx + ry * ry) * anisotropy;
        if (cx - r < minX) {
          minX = cx - r;
        }
        if (cy - r < minY) {
          minY = cy - r;
        }
        if (cz - r < minZ) {
          minZ = cz - r;
        }
        if (cx + r > maxX) {
          maxX = cx + r;
        }
        if (cy + r > maxY) {
          maxY = cy + r;
        }
        if (cz + r > maxZ) {
          maxZ = cz + r;
        }
      }
      _localAabb.min.setValues(minX, minY, minZ);
      _localAabb.max.setValues(maxX, maxY, maxZ);
    }
    return _localAabb;
  }

  final Vector3 _sortCenter = Vector3.zero();

  @override
  void draw(covariant RenderContext3D context) {
    drawTransformed(context, worldTransformMatrix);
  }

  /// Records the draw of this batch with its billboards placed by
  /// [transform] instead of [worldTransformMatrix], for a component that
  /// draws a batch it does not mount.
  @internal
  void drawTransformed(RenderContext3D context, Matrix4 transform) {
    if (_length == 0 || context.isShadowPass) {
      return;
    }
    final box = computeLocalAabb()!;
    _sortCenter
      ..setFrom(box.min)
      ..add(box.max)
      ..scale(0.5);
    transform.transform3(_sortCenter);
    context.drawInstances(
      _unitQuad,
      instances: transform.isIdentity() ? _instances : _placed(transform),
      count: _length,
      material: material,
      center: _sortCenter,
    );
  }

  /// The instances placed in world space by [transform]: centers
  /// transformed, up axes rotated, sizes scaled by the largest axis scale.
  Float32List _placed(Matrix4 transform) {
    final m = transform.storage;
    final cached = _worldInstancesTransform;
    var same = !_worldInstancesDirty;
    for (var i = 0; same && i < 16; i++) {
      same = cached[i] == m[i];
    }
    var out = _worldInstances;
    if (same && out != null && out.length >= _length * _stride) {
      return out;
    }
    if (out == null || out.length < _instances.length) {
      out = _worldInstances = Float32List(_instances.length);
    }
    for (var i = 0; i < 16; i++) {
      cached[i] = m[i];
    }
    _worldInstancesDirty = false;
    final scale = transform.getMaxScaleOnAxis();
    final src = _instances;
    out.setRange(0, _length * _stride, src);
    for (var i = 0; i < _length; i++) {
      final b = i * _stride;
      final x = src[b];
      final y = src[b + 1];
      final z = src[b + 2];
      out[b] = m[0] * x + m[4] * y + m[8] * z + m[12];
      out[b + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
      out[b + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
      out[b + 3] = src[b + 3] * scale;
      final ux = src[b + 4];
      final uy = src[b + 5];
      final uz = src[b + 6];
      final tx = m[0] * ux + m[4] * uy + m[8] * uz;
      final ty = m[1] * ux + m[5] * uy + m[9] * uz;
      final tz = m[2] * ux + m[6] * uy + m[10] * uz;
      out[b + 4] = tx;
      out[b + 5] = ty;
      out[b + 6] = tz;
      out[b + 7] = src[b + 7] * scale;
      if (src[b + 15] > 1.5) {
        // A fixed sprite: turn its right direction too.
        _fixedReference(ux, uy, uz);
        final r = _reference;
        final angle = src[b + 13];
        final c = math.cos(angle);
        final sn = math.sin(angle);
        final rx = r[0] * c + r[3] * sn;
        final ry = r[1] * c + r[4] * sn;
        final rz = r[2] * c + r[5] * sn;
        out[b + 13] = _fixedRightAngle(
          tx,
          ty,
          tz,
          m[0] * rx + m[4] * ry + m[8] * rz,
          m[1] * rx + m[5] * ry + m[9] * rz,
          m[2] * rx + m[6] * ry + m[10] * rz,
        );
      }
    }
    return out;
  }

  // The two directions perpendicular to an up axis that the right direction
  // of a fixed sprite is measured from, as billboardFixedRight in
  // shaders/flame_3d/billboard_vertex.glsl computes them: r0 (0..2), the
  // direction closest to +X (to -Z for an up axis along X), and r1 (3..5),
  // up × r0.
  static final Float64List _reference = Float64List(6);

  static void _fixedReference(double upX, double upY, double upZ) {
    final length = math.sqrt(upX * upX + upY * upY + upZ * upZ);
    final valid = length > 1e-5;
    final ux = valid ? upX / length : 0.0;
    final uy = valid ? upY / length : 1.0;
    final uz = valid ? upZ / length : 0.0;
    final alongX = ux.abs() >= 0.99;
    final ax = alongX ? 0.0 : 1.0;
    final az = alongX ? -1.0 : 0.0;
    final d = ax * ux + az * uz;
    var r0x = ax - ux * d;
    var r0y = -uy * d;
    var r0z = az - uz * d;
    final r0Length = math.sqrt(r0x * r0x + r0y * r0y + r0z * r0z);
    r0x /= r0Length;
    r0y /= r0Length;
    r0z /= r0Length;
    _reference
      ..[0] = r0x
      ..[1] = r0y
      ..[2] = r0z
      ..[3] = uy * r0z - uz * r0y
      ..[4] = uz * r0x - ux * r0z
      ..[5] = ux * r0y - uy * r0x;
  }

  /// The angle about the up axis ([ux], [uy], [uz]) of the right direction
  /// ([rx], [ry], [rz]) of a fixed sprite, as the shader reads it.
  static double _fixedRightAngle(
    double ux,
    double uy,
    double uz,
    double rx,
    double ry,
    double rz,
  ) {
    _fixedReference(ux, uy, uz);
    final r = _reference;
    return math.atan2(
      rx * r[3] + ry * r[4] + rz * r[5],
      rx * r[0] + ry * r[1] + rz * r[2],
    );
  }
}
