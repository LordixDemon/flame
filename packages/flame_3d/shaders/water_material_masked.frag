#version 460 core

// WaterMaterial's full fragment stage: the stage of water_material.frag with
// 16 slots of foam sources (16 more uniform vectors), which can carry their
// pattern. WaterMaterial takes it from this bundle, whose own vertex stage
// draws WaterMaterial.vertexLayout, for any layout, when its
// WaterFoamSources holds more than 8 sources or carries a pattern.
#define WATER_FOAM_SOURCE_SLOTS 16
#define WATER_FOAM_CARRIED_PATTERNS
#include <flame_3d/water_material_fragment.glsl>
