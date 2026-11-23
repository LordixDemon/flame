part of 'render_context_3d.dart';

class _CameraPassState() {
  final Matrix4 modelMatrix = Matrix4.identity();
  final Matrix4 viewMatrix = Matrix4.identity();
  final Matrix4 projectionMatrix = Matrix4.identity();
  final Matrix4 viewProjectionMatrix = Matrix4.identity();
  final Matrix4 _inverseView = Matrix4.identity();
  final Matrix4 _inverseViewProj = Matrix4.zero();
  final Vector3 cameraPosition = Vector3.zero();
  final Vector3 shadowViewerPosition = Vector3.zero();
  final Matrix4 shadowViewerViewProjection = Matrix4.identity();
  final Frustum frustum = Frustum();
  final Float64List depthRow = Float64List(4);

  bool isMirrored = false;
  int viewerEpoch = 0;

  int _viewerPass = -1;
  double _viewerX = 0;
  double _viewerY = 0;
  double _viewerZ = 0;
  double _viewerW = 1;

  void setCamera(
    Matrix4 view,
    Matrix4 projection, {
    required bool isRecordingShadow,
  }) {
    if (!isRecordingShadow) {
      viewerEpoch++;
    }
    viewMatrix.setFrom(view);
    projectionMatrix.setFrom(projection);
    viewProjectionMatrix
      ..setFrom(projection)
      ..multiply(view);
    _inverseView.copyInverse(view);
    cameraPosition.setValues(
      _inverseView.storage[12],
      _inverseView.storage[13],
      _inverseView.storage[14],
    );
    frustum.setFromViewProjection(viewProjectionMatrix);

    final m = viewProjectionMatrix.storage;
    final perspective = m[3] * m[3] + m[7] * m[7] + m[11] * m[11] > 1e-12;
    final depthRowIndex = perspective ? 3 : 2;
    for (var i = 0; i < 4; i++) {
      depthRow[i] = m[i * 4 + depthRowIndex];
    }
    isMirrored = mirrors(viewProjectionMatrix);
  }

  void saveSnapshot(_CameraSnapshot out) {
    out.view.setFrom(viewMatrix);
    out.projection.setFrom(projectionMatrix);
    out.viewProjection.setFrom(viewProjectionMatrix);
    out.cameraPosition.setFrom(cameraPosition);
    out.depthRow.setAll(0, depthRow);
    out.isMirrored = isMirrored;
    _copyFrustum(out.frustum, frustum);
  }

  void restoreSnapshot(_CameraSnapshot snap) {
    viewMatrix.setFrom(snap.view);
    projectionMatrix.setFrom(snap.projection);
    viewProjectionMatrix.setFrom(snap.viewProjection);
    cameraPosition.setFrom(snap.cameraPosition);
    depthRow.setAll(0, snap.depthRow);
    isMirrored = snap.isMirrored;
    _copyFrustum(frustum, snap.frustum);
  }

  void writeViewerTo(int cameraPass, UniformBlock block, int offset) {
    if (_viewerPass != cameraPass) {
      _viewerPass = cameraPass;
      final inverse = _inverseViewProj..setFrom(viewProjectionMatrix);
      final determinant = inverse.invert();
      final s = inverse.storage;
      final x = s[8];
      final y = s[9];
      final z = s[10];
      final w = s[11];
      final length = math.sqrt(x * x + y * y + z * z);
      if (determinant == 0 || !(length > 0)) {
        _viewerX = cameraPosition.x;
        _viewerY = cameraPosition.y;
        _viewerZ = cameraPosition.z;
        _viewerW = 1;
      } else if (w.abs() > 1e-9 * length) {
        _viewerX = x / w;
        _viewerY = y / w;
        _viewerZ = z / w;
        _viewerW = 1;
      } else {
        _viewerX = -x / length;
        _viewerY = -y / length;
        _viewerZ = -z / length;
        _viewerW = 0;
      }
    }
    block.writeVec4ValuesAt(offset, _viewerX, _viewerY, _viewerZ, _viewerW);
  }

  static bool mirrors(Matrix4 m) {
    final s = m.storage;
    final perspective = s[3] * s[3] + s[7] * s[7] + s[11] * s[11] > 1e-12;
    final r = perspective ? 3 : 2;
    final det =
        s[0] * (s[5] * s[8 + r] - s[9] * s[4 + r]) -
        s[4] * (s[1] * s[8 + r] - s[9] * s[r]) +
        s[8] * (s[1] * s[4 + r] - s[5] * s[r]);
    return det > 0;
  }
}

class _CameraSnapshot() {
  final Matrix4 view = Matrix4.identity();
  final Matrix4 projection = Matrix4.identity();
  final Matrix4 viewProjection = Matrix4.identity();
  final Vector3 cameraPosition = Vector3.zero();
  final Float64List depthRow = Float64List(4);
  final Frustum frustum = Frustum();
  bool isMirrored = false;
}

void _copyFrustum(Frustum dst, Frustum src) {
  dst.plane0
    ..normal.setFrom(src.plane0.normal)
    ..constant = src.plane0.constant;
  dst.plane1
    ..normal.setFrom(src.plane1.normal)
    ..constant = src.plane1.constant;
  dst.plane2
    ..normal.setFrom(src.plane2.normal)
    ..constant = src.plane2.constant;
  dst.plane3
    ..normal.setFrom(src.plane3.normal)
    ..constant = src.plane3.constant;
  dst.plane4
    ..normal.setFrom(src.plane4.normal)
    ..constant = src.plane4.constant;
  dst.plane5
    ..normal.setFrom(src.plane5.normal)
    ..constant = src.plane5.constant;
}
