#ifndef FLAME_STYLIZED_INSTANCE_DATA_GLSL_
#define FLAME_STYLIZED_INSTANCE_DATA_GLSL_

// The instance data StylizedMaterial's vertex stages pass to its fragment
// stage (flame_3d/stylized_material_fragment.glsl) in `fragInstanceData`,
// made from the instance data of the draw:
//
// - x: the emissive boost, as it is;
// - y: the highlight, as it is;
// - z: the palette slot `a + 17 * r`, with `a` and `r` the accent and rim
//   palette indices plus one (`0`: none), a whole number from 0 to 152;
// - w: the fade.
//
// `instanceData.w` is a plain fade below 2, and otherwise the slot and the
// fade packed as `slot * 4 + fade` by StylizedMaterial.packPaletteAndFade.
// The z of the instance data (the wind strength) is only read by the vertex
// stage, which leaves its place free for the slot.
//
// The packed value is decoded here, where it is the exact per-instance value
// of every vertex of the instance, rather than in the fragment stage, where it
// arrives interpolated across the triangle (or extrapolated to the samples
// outside it, with MSAA) and so a few ulps off: just below a slot boundary,
// the decoding there read the previous slot with a fade of nearly 1. Here
// `w * 0.25` and `floor` are exact, and so is `w - slot * 4` (both are whole
// multiples of the precision of `w`), so the fade passed on is the very value
// a plain fade of the same float would be; the fragment stage clamps it like
// one. The slot is a small whole number, which the fragment stage rounds to
// the nearest: no interpolation error comes near 0.5. Neither needs a `flat`
// varying, which GLSL ES 1.00 (the OpenGL ES backend) does not have.
vec4 stylizedFragmentInstanceData(vec4 data) {
  float slot = 0.0;
  float fade = data.w;
  if (data.w >= 2.0) {
    slot = floor(data.w * 0.25);
    fade = data.w - slot * 4.0;
  }
  return vec4(data.x, data.y, slot, fade);
}

#endif
