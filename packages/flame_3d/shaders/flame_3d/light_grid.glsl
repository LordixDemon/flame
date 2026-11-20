#ifndef FLAME_LIGHT_GRID_GLSL_
#define FLAME_LIGHT_GRID_GLSL_

// The light grid of the render pass (World3D.lightGrid), filled by flame_3d
// once per pass for every fragment shader that declares it: the point and
// spot lights of a pass that has more of them than the blocks of
// flame_3d/lights.glsl hold, binned into cubic cells in world space. A
// fragment shades the first `counts.x` point lights of the Lights block and
// the first `counts.y` spot lights of the SpotLights block, then the lights
// of its cell (lightGridCell): the lights of the blocks after those are in
// the grid too, for the shaders that do not read it.
//
// A material whose shader reads the grid lists the `LightGrid` block and the
// `lightGridTexture` sampler in its slots. Without a grid, `counts.xy` is
// (8, 4), so `min(numLights, counts.x)` is every light of the block, and the
// cells hold nothing (`data.w` is 0).
//
// `origin.xyz` is the world position of the corner of cell (0, 0, 0) and
// `origin.w` the inverse of the edge of a cell; `cells.xyz` the number of
// cells along x, y and z and `cells.w` is `cells.x * cells.y`; `data.x` is
// the width of the texture in texels, `data.y` its inverse, `data.z` the
// inverse of its height, and `data.w` 1 when the grid holds lights.
//
// The texture holds 4 floats per texel, read at texel centers with nearest
// filtering: the first texels are the headers of the cells,
// `(first point light texel, point lights, first spot light texel, spot
// lights)`; a point light takes two texels, `(position, range)` and
// `(color, intensity)`, and a spot light four: those two, then
// `(direction towards the light, specular)` and
// `(cos outer, 1 / (cos inner - cos outer), 0, 0)`, the values of the
// blocks. The lights of a cell come in the order of the lights of the pass,
// and every light that reaches a point of the cell is listed (up to
// LIGHT_GRID_POINT_LIGHTS_PER_CELL and LIGHT_GRID_SPOT_LIGHTS_PER_CELL, or
// the smaller numbers of LightGridSettings); a listed light may not reach
// the fragment, and then adds nothing to it. Grid lights cast no shadows.
//
// A shader that reads these values from a block of its own (as
// StylizedMaterial does) defines `FLAME_LIGHT_GRID(member)` to the
// expression of the member named `member` before including this file, which
// then declares no LightGrid block.
//
// Written for GLSL ES 1.00 too (the OpenGL ES backend): no integer
// operations, no explicit level of detail, and loops with constant bounds.
//
// Only the native builds (Metal, Vulkan, OpenGL ES: the shader bundle
// compiler defines IMPELLER_TARGET_* for each) read a grid, and define
// FLAME_LIGHT_GRID_ENABLED. The WebGPU build declares neither the block nor
// the sampler: its functions below shade every light of the blocks and find
// no light in any cell, so the same shader source builds for the web.

// The most lights a cell lists: the bounds of the loops over them.
#define LIGHT_GRID_POINT_LIGHTS_PER_CELL 32
#define LIGHT_GRID_SPOT_LIGHTS_PER_CELL 16

#ifdef IMPELLER_TARGET_METAL
#define FLAME_LIGHT_GRID_ENABLED
#endif
#ifdef IMPELLER_TARGET_VULKAN
#define FLAME_LIGHT_GRID_ENABLED
#endif
#ifdef IMPELLER_TARGET_OPENGLES
#define FLAME_LIGHT_GRID_ENABLED
#endif
#ifdef IMPELLER_TARGET_OPENGL
#define FLAME_LIGHT_GRID_ENABLED
#endif

#ifdef FLAME_LIGHT_GRID_ENABLED
uniform sampler2D lightGridTexture;

#ifndef FLAME_LIGHT_GRID
uniform LightGrid {
  vec4 origin;
  vec4 cells;
  vec4 data;
  vec4 counts;
} lightGrid;
#define FLAME_LIGHT_GRID(member) lightGrid.member
#endif

// The number of point lights of the Lights block to shade, of `numLights`.
float lightGridBlockPointLights(float numLights) {
  return min(numLights, FLAME_LIGHT_GRID(counts).x);
}

// The number of spot lights of the SpotLights block to shade, of
// `numLights`.
float lightGridBlockSpotLights(float numLights) {
  return min(numLights, FLAME_LIGHT_GRID(counts).y);
}

// The texel at `index` of the grid's texture.
vec4 lightGridTexel(float index) {
  vec4 data = FLAME_LIGHT_GRID(data);
  float row = floor(index * data.y);
  float column = index - row * data.x;
  return texture(
    lightGridTexture,
    vec2((column + 0.5) * data.y, (row + 0.5) * data.z)
  );
}

// The header of the cell of the grid around `worldPosition`:
// `(first point light texel, point lights, first spot light texel, spot
// lights)`, all 0 outside the grid or without one.
vec4 lightGridCell(vec3 worldPosition) {
  if (FLAME_LIGHT_GRID(data).w < 0.5) {
    return vec4(0.0);
  }
  vec4 origin = FLAME_LIGHT_GRID(origin);
  vec4 cells = FLAME_LIGHT_GRID(cells);
  vec3 cell = floor((worldPosition - origin.xyz) * origin.w);
  if (any(lessThan(cell, vec3(0.0))) ||
      any(greaterThanEqual(cell, cells.xyz))) {
    return vec4(0.0);
  }
  return lightGridTexel(cell.x + cell.y * cells.x + cell.z * cells.w);
}

// Point light `k` of the cell whose header is `cell`: `(position, range)`
// and `(color, intensity)`.
void lightGridPointLight(
  vec4 cell,
  int k,
  out vec4 positionRange,
  out vec4 colorIntensity
) {
  float at = cell.x + float(k) * 2.0;
  positionRange = lightGridTexel(at);
  colorIntensity = lightGridTexel(at + 1.0);
}

// Spot light `k` of the cell whose header is `cell`: `(position, range)`,
// `(color, intensity)`, `(direction towards the light, specular)` and
// `(cos outer, 1 / (cos inner - cos outer), 0, 0)`.
void lightGridSpotLight(
  vec4 cell,
  int k,
  out vec4 positionRange,
  out vec4 colorIntensity,
  out vec4 direction,
  out vec4 cone
) {
  float at = cell.z + float(k) * 4.0;
  positionRange = lightGridTexel(at);
  colorIntensity = lightGridTexel(at + 1.0);
  direction = lightGridTexel(at + 2.0);
  cone = lightGridTexel(at + 3.0);
}
#else
// The WebGPU build: every light is in the blocks, none in a grid.
float lightGridBlockPointLights(float numLights) {
  return numLights;
}

float lightGridBlockSpotLights(float numLights) {
  return numLights;
}

vec4 lightGridCell(vec3 worldPosition) {
  return vec4(0.0);
}

void lightGridPointLight(
  vec4 cell,
  int k,
  out vec4 positionRange,
  out vec4 colorIntensity
) {
  positionRange = vec4(0.0, 0.0, 0.0, 1.0);
  colorIntensity = vec4(0.0);
}

void lightGridSpotLight(
  vec4 cell,
  int k,
  out vec4 positionRange,
  out vec4 colorIntensity,
  out vec4 direction,
  out vec4 cone
) {
  positionRange = vec4(0.0, 0.0, 0.0, 1.0);
  colorIntensity = vec4(0.0);
  direction = vec4(0.0);
  cone = vec4(0.0);
}
#endif

#endif
