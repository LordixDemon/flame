#ifndef FLAME_SKINNING_GLSL_
#define FLAME_SKINNING_GLSL_

in vec4 vertexJoints;
in vec4 vertexWeights;

// The joint matrices of the draw, at most 64, as their top three rows: row r
// of joint j is `jointRows[j * 3 + r]`. The bottom row of a joint matrix is
// (0, 0, 0, 1), as it is for every affine transform, so it is not stored:
// 192 vectors rather than the 256 of 64 whole matrices, which leaves room
// within the 256 uniform vectors an OpenGL ES 3.0 vertex shader may be
// limited to. flame_3d writes the rows of the joint matrices it is given (and
// whole matrices into a block that declares `mat4 joints[64]` instead).
uniform JointMatrices {
  vec4 jointRows[192];
} jointMatrices;

// The weighted sum of the joint matrices of the vertex. It is the sum of the
// whole matrices: the bottom row is (0, 0, 0, w) with w the sum of the
// weights, added up in the order the matrices are.
mat4 computeSkinMatrix() {
  if (vertexWeights.x == 0.0 && vertexWeights.y == 0.0 && vertexWeights.z == 0.0 && vertexWeights.w == 0.0) {
    return mat4(1.0);
  }

  int j0 = int(vertexJoints.x) * 3;
  int j1 = int(vertexJoints.y) * 3;
  int j2 = int(vertexJoints.z) * 3;
  int j3 = int(vertexJoints.w) * 3;
  vec4 row0 = vertexWeights.x * jointMatrices.jointRows[j0] +
    vertexWeights.y * jointMatrices.jointRows[j1] +
    vertexWeights.z * jointMatrices.jointRows[j2] +
    vertexWeights.w * jointMatrices.jointRows[j3];
  vec4 row1 = vertexWeights.x * jointMatrices.jointRows[j0 + 1] +
    vertexWeights.y * jointMatrices.jointRows[j1 + 1] +
    vertexWeights.z * jointMatrices.jointRows[j2 + 1] +
    vertexWeights.w * jointMatrices.jointRows[j3 + 1];
  vec4 row2 = vertexWeights.x * jointMatrices.jointRows[j0 + 2] +
    vertexWeights.y * jointMatrices.jointRows[j1 + 2] +
    vertexWeights.z * jointMatrices.jointRows[j2 + 2] +
    vertexWeights.w * jointMatrices.jointRows[j3 + 2];
  float w = vertexWeights.x + vertexWeights.y + vertexWeights.z +
    vertexWeights.w;
  // Column-major: column c is (row0[c], row1[c], row2[c], bottom row[c]).
  return mat4(
    row0.x, row1.x, row2.x, 0.0,
    row0.y, row1.y, row2.y, 0.0,
    row0.z, row1.z, row2.z, 0.0,
    row0.w, row1.w, row2.w, w
  );
}

#endif
