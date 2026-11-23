#ifndef FLAME_RIGID_BATCH_GLSL_
#define FLAME_RIGID_BATCH_GLSL_

in float vertexObjectId;

// Up to 40 rigid objects packed into one std140 uniform block:
// - modelRows[0..119]: 3 transposed vec4 rows per object (1920 bytes)
// - colors[0..39]: per-object RGBA tint (640 bytes)
// - data[0..39]: per-object instanceData vec4 (640 bytes)
// Shadow casters define FLAME_RIGID_BATCH_TRANSFORMS_ONLY to declare only
// modelRows[120] and bind offset 0 (first 1920 bytes) of the same buffer.
uniform BatchObjects {
  vec4 modelRows[120];
#ifndef FLAME_RIGID_BATCH_TRANSFORMS_ONLY
  vec4 colors[40];
  vec4 data[40];
#endif
} batchObjects;

mat4 batchObjectModelMatrix(int id) {
  int base = id * 3;
  vec4 r0 = batchObjects.modelRows[base];
  vec4 r1 = batchObjects.modelRows[base + 1];
  vec4 r2 = batchObjects.modelRows[base + 2];
  return mat4(
    r0.x, r1.x, r2.x, 0.0,
    r0.y, r1.y, r2.y, 0.0,
    r0.z, r1.z, r2.z, 0.0,
    r0.w, r1.w, r2.w, 1.0
  );
}

#endif
