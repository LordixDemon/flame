#ifndef FLAME_PARTICLE_VERTEX_GLSL_
#define FLAME_PARTICLE_VERTEX_GLSL_

// The camera-facing quads of the particles of `ParticleSystem3D` drawn with
// `ParticleMaterial`, shared by the material and its depth-normal prepass
// variant. Include it after <flame_3d/instancing.glsl>. The vertices are the
// corners of a unit quad, the instance inputs hold the particle (see
// ParticleMaterial and ParticleSystem3D, which write them):
//
// - instanceModel0: the center (xyz, world space) and the width (w);
// - instanceModel1: the velocity (xyz, world space) and the height (w);
// - instanceModel2: the rotation in radians (x), the flipbook frame (y, its
//   fraction blends to the next frame), a random seed in [0, 1) (z) and the
//   stretch along the velocity (w);
// - instanceModel3: the life progress in [0, 1] (x);
// - instanceColor: the color, straight alpha.

// Written by ParticleMaterial for each render pass.
uniform ParticleBillboard {
  // xyz: the world direction that points right on screen; w: the billboard
  // mode (0 spherical, 1 cylindrical, 2 velocity, 3 flat).
  vec4 right;
  // xyz: the world direction that points up on screen; w: 1 when the camera
  // has a perspective projection.
  vec4 up;
  // xyz: the unit vector towards the viewer of an orthographic camera.
  vec4 back;
  // xyz: the position of the camera.
  vec4 eye;
  // xyz: the locked axis of cylindrical billboards.
  vec4 axis;
  // xyz: the axes of the plane of flat billboards.
  vec4 flatX;
  vec4 flatY;
  // x: columns, y: rows, z: frames of the flipbook; w: 1 to blend frames.
  vec4 flipbook;
} billboard;

vec2 frameTexCoord(float frame, vec2 texCoord) {
  float columns = billboard.flipbook.x;
  float rows = billboard.flipbook.y;
  float column = mod(frame, columns);
  float row = floor(frame / columns);
  return (vec2(column, row) + texCoord) / vec2(columns, rows);
}

// The world position of the corner [quadCorner] (each coordinate -0.5 or
// 0.5) of the quad of the particle of the instance.
vec3 particleCorner(vec2 quadCorner) {
  // Reads every instance input, see instancing.glsl.
  mat4 particle = instanceModelMatrix();
  vec3 center = particle[0].xyz;
  vec2 size = vec2(particle[0].w, particle[1].w);
  vec3 velocity = particle[1].xyz;
  float rotation = particle[2].x;
  float stretch = particle[2].w;

  float mode = billboard.right.w;
  vec3 right = billboard.right.xyz;
  vec3 toViewer = billboard.up.w > 0.5
      ? normalize(billboard.eye.xyz - center)
      : billboard.back.xyz;
  vec3 xAxis = right;
  vec3 yAxis = billboard.up.xyz;
  float shift = 0.0;
  if (mode > 2.5) {
    // Flat: in a fixed plane, such as the ground.
    xAxis = billboard.flatX.xyz;
    yAxis = billboard.flatY.xyz;
  } else if (mode > 1.5) {
    // Velocity: stretched along the velocity seen on screen, the leading edge
    // half a size ahead of the particle.
    vec3 along = velocity - dot(velocity, toViewer) * toViewer;
    float alongLength = length(along);
    if (alongLength > 1e-6) {
      yAxis = along / alongLength;
      xAxis = normalize(cross(yAxis, toViewer));
      if (dot(xAxis, right) < 0.0) {
        xAxis = -xAxis;
      }
    }
    shift = size.y * (stretch - 1.0) * 0.5;
    size.y *= stretch;
    rotation = 0.0;
  } else if (mode > 0.5) {
    // Cylindrical: turns about the locked axis only.
    yAxis = billboard.axis.xyz;
    vec3 side = cross(yAxis, toViewer);
    float sideLength = length(side);
    if (sideLength > 1e-6) {
      xAxis = side / sideLength;
      if (dot(xAxis, right) < 0.0) {
        xAxis = -xAxis;
      }
    }
  }

  vec2 corner = quadCorner * size;
  float c = cos(rotation);
  float s = sin(rotation);
  vec2 turned = vec2(c * corner.x - s * corner.y, s * corner.x + c * corner.y);
  return center + xAxis * turned.x + yAxis * (turned.y - shift);
}

// The texture coordinates of [texCoord] in the flipbook frame of the
// particle (xy) and in the next frame (zw).
vec4 particleTexCoords(vec2 texCoord) {
  float frame = instanceModel2.y;
  float frames = billboard.flipbook.z;
  float frame0 = mod(floor(frame), frames);
  float frame1 = mod(frame0 + 1.0, frames);
  return vec4(frameTexCoord(frame0, texCoord), frameTexCoord(frame1, texCoord));
}

// The values the fragment shader reads per particle: the blend towards the
// next flipbook frame (x), the seed (y) and the life progress (z).
vec4 particleParams() {
  return vec4(
    fract(instanceModel2.y) * billboard.flipbook.w,
    instanceModel2.z,
    instanceModel3.x,
    0.0
  );
}

#endif
