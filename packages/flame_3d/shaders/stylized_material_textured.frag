#version 460 core

// The fragment stage of StylizedMaterial with a base color texture, which
// multiplies or replaces the vertex color (see
// flame_3d/stylized_material_fragment.glsl). Every textured vertex stage
// feeds it.

#define FLAME_STYLIZED_TEXTURED
#include <flame_3d/stylized_material_fragment.glsl>
