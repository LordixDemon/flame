#version 460 core

// WaterMaterial's lean fragment stage, see
// flame_3d/water_material_fragment.glsl: 8 slots of foam sources, none of
// which carries its pattern. water_material_masked.frag holds the full one.
#include <flame_3d/water_material_fragment.glsl>
