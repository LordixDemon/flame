#ifndef FLAME_WATER_PATTERN_GLSL_
#define FLAME_WATER_PATTERN_GLSL_

// Procedural patterns of water, shared by WaterMaterial (its surface) and by
// the submerged surfaces of a World3D.waterVolume (flame_3d/water_volume.glsl),
// so that both show the same caustics.
//
// Everything is built from sines of small arguments: no hash with large
// constants, no texture, no derivative, no explicit level of detail and only
// loops with constant bounds, so it compiles to GLSL ES 1.00 and keeps its
// precision when evaluated in 16-bit floats. Each pattern takes a `phase` in
// [0, 2π) that its animation repeats over: every term moves with a whole
// multiple of it, so an animation loops exactly over one period, and the
// material wraps the time on the CPU (`phase = 2π * fract(time / period)`),
// which keeps the argument small however long the game runs.

const float WATER_TAU = 6.283185307;

// The caustic network at the world point whose coordinates in the plane of
// the water are `uv`, in units of the pattern's cells: bright, thin, wavy
// lines of light between darker cells, as a rippled surface focuses them,
// about 1 on the lines (up to 1.2 where the cells are small and the light
// most focused) and 0 inside the cells.
//
// The lines are the borders of a Voronoi diagram of one point per cell (the
// distance to the second nearest point less the distance to the nearest),
// whose points sway and whose domain is warped by slow waves, so the walls
// are curved and keep changing shape. The cells' pseudo-random values come
// from their coordinates wrapped to 64, so the network repeats only every
// 64 cells.
float waterCaustics(vec2 uv, float phase) {
  vec2 w = uv + 0.2 * vec2(
    sin(uv.y * 2.1 + phase),
    cos(uv.x * 1.9 - phase)
  ) + 0.1 * vec2(
    sin(uv.y * 4.3 - uv.x * 1.7 + 2.0 * phase),
    cos(uv.x * 3.7 + uv.y * 2.3 - 2.0 * phase)
  );
  vec2 cell = floor(w);
  vec2 f = w - cell;
  // The squares of the distances to the nearest and second nearest points.
  float near1 = 9.0;
  float near2 = 9.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 o = vec2(float(i), float(j));
      vec2 id = mod(cell + o, 64.0);
      float s = sin(dot(id, vec2(1.731, 2.417)) + 0.3);
      float h1 = fract(s * 7.31 + 0.5);
      float h2 = fract(s * 5.17 + 0.25);
      float h3 = fract(s * 3.71 + 0.75);
      float sway = 0.5 * sin(phase + h3 * WATER_TAU);
      vec2 d = o + 0.2 + 0.6 * vec2(h1, h2) + sway * vec2(h2 - 0.5, 0.5 - h1) - f;
      float dd = dot(d, d);
      if (dd < near1) {
        near2 = near1;
        near1 = dd;
      } else if (dd < near2) {
        near2 = dd;
      }
    }
  }
  float f1 = sqrt(near1);
  float f2 = sqrt(near2);
  float line = 1.0 - smoothstep(0.0, 0.1, f2 - f1);
  return line * clamp(1.5 - (f1 + f2), 0.25, 1.2);
}

// A smooth, organic noise in about [-1, 1] at `p` (in radians, features
// about 3 units across), from domain-warped sines: blobs that drift and
// change shape over the phase.
float waterNoise(vec2 p, float phase) {
  float a = sin(p.x * 1.07 + sin(p.y * 0.83 + phase) * 1.3);
  float b = sin(p.y * 1.21 + sin(p.x * 0.71 - phase) * 1.4 + 1.7);
  float c = sin((p.x + p.y) * 0.77 + sin(p.x * 0.53 - p.y * 0.61) + phase);
  return (a + b + c) * (1.0 / 3.0);
}

// The gradient (in the plane of the water) of a gentle swell made of six
// small waves of different directions and lengths travelling across the
// surface, for normals that make the highlights of lights move and glitter.
// `uv` is in units of the longest wave's length; each wave travels a whole
// number of its own lengths per period.
vec2 waterDetailSlope(vec2 uv, float phase) {
  vec2 x = uv * WATER_TAU;
  vec2 d0 = vec2(0.9285, 0.3714);
  vec2 d1 = vec2(-0.4472, 0.8944);
  vec2 d2 = vec2(0.2425, -0.9701);
  vec2 d3 = vec2(-0.8, -0.6);
  vec2 d4 = vec2(0.9950, -0.0995);
  vec2 d5 = vec2(0.5145, 0.8575);
  vec2 slope =
    d0 * (0.50 * cos(dot(x, d0) - phase)) +
    d1 * (0.42 * cos(dot(x, d1) * 1.31 - phase * 2.0 + 1.3)) +
    d2 * (0.36 * cos(dot(x, d2) * 1.73 + phase * 2.0 + 2.9)) +
    d3 * (0.30 * cos(dot(x, d3) * 2.29 - phase * 3.0 + 0.4)) +
    d4 * (0.25 * cos(dot(x, d4) * 2.97 + phase * 4.0 + 4.1)) +
    d5 * (0.20 * cos(dot(x, d5) * 3.83 - phase * 5.0 + 5.3));
  return slope * 0.5;
}

// Sparkles: tiny points that flash briefly, one per cell of a grid of
// `uv` (in units of a cell), each at its own place in its cell and its own
// moment of the period; 0 elsewhere, up to 1 at the center of a flash.
float waterSparkle(vec2 uv, float phase) {
  vec2 cell = floor(uv);
  vec2 local = uv - cell;
  // Pseudo-random per cell from sines of small multiples of its (whole)
  // coordinates: the same value for every pixel of the cell. The cell index
  // is wrapped to keep the arguments small.
  vec2 id = mod(cell, 64.0);
  float h1 = fract(sin(dot(id, vec2(1.731, 2.417))) * 7.31 + 0.5);
  float h2 = fract(sin(dot(id, vec2(2.913, 0.839)) + 1.3) * 5.17 + 0.5);
  float h3 = fract(sin(dot(id, vec2(0.677, 3.187)) + 2.1) * 6.43 + 0.5);
  vec2 center = 0.25 + 0.5 * vec2(h1, h2);
  float dist = length(local - center);
  // Each point flashes twice per period, at a moment of its own.
  float flash = max(sin(phase * 2.0 + h3 * WATER_TAU), 0.0);
  flash *= flash;
  flash *= flash;
  float radius = 0.05 + 0.07 * flash;
  float point = max(1.0 - dist / radius, 0.0);
  return point * point * flash;
}

#endif
