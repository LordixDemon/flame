#version 460 core

// A translucent energy wall (`BarrierMaterial`), the lean variant: brightest
// at its foot and thinner above, rising from the foot with the appear factor,
// with a slow procedural pattern travelling along it in one row, a glint
// where it is seen edge-on, the near side thinned, up to four impacts, each a
// ring spreading over the wall and a local flash, a pulse of the whole wall
// and points that light the wall where they come close. `BarrierMaterial`
// draws with it while every option of `barrier_material_full.frag` is off: it
// computes what the barrier's shader computed before those options existed,
// with only constants turned into uniforms (the ring and flash strengths, the
// flash's length, the twinkle's depth, the line width, the motif color, the
// softness of the near-side fade), and costs what it cost.
//
// The output is premultiplied (`glint.z` > 0.5) or straight, with an alpha of
// the brightest channel: added as it is by additive blending, which keeps the
// target's alpha, or laid over the target by alpha blending.

#include "barrier_material_shared.glsl"

void main() {
  float v = clamp(fragWall.y, 0.0, 1.0);
  float appear = barrier.shape.x;
  float soft = max(barrier.glint.w, 1e-3);

  // The rising front: everything below it is shown.
  float front = appear * (1.0 + soft);
  float mask = 1.0 - smoothstep(front - soft, front, v);
  if (mask <= 0.0) {
    discard;
  }
  float frontLine = (v - (front - soft * 0.5)) / (soft * 0.5);
  float frontGlow = exp(-frontLine * frontLine) *
      clamp(4.0 * appear * (1.0 - appear), 0.0, 1.0) * 0.8;

  // Brightest at the foot, thinner above.
  float profile = pow(1.0 - v, max(barrier.shape.y, 0.01));
  vec3 tint = mix(barrier.footColor.rgb, barrier.topColor.rgb, v);
  float body = profile * mix(barrier.footColor.a, barrier.topColor.a, v) +
      barrier.shape.w * barrier.footColor.a * exp(-v * 24.0);

  vec4 near = vec4(0.0);
  if (barrier.proximity.z > 0.5) {
    near = nearGlow();
  }

  // The pattern travelling along the wall, in a band above the foot.
  float motifValue = 0.0;
  float band = max(barrier.patternExtra.x, 1e-3);
  float y = v / band;
  if (barrier.pattern.x > 0.5 && y < 1.0) {
    float x = fragWall.x * barrier.pattern.y - barrier.pattern.z;
    float period = max(barrier.patternExtra.y, 1.0);
    float cell = mod(floor(x), period);
    float f = fract(x);
    if (barrier.patternExtra.z < 0.0) {
      f = 1.0 - f;
    }
    float depth = barrier.patternStyle.z;
    float twinkle = (1.0 - depth) +
        depth * sin(barrier.patternExtra.w + hash(cell + 5.0) * 6.2831853);
    motifValue = motifAtClassic(
          barrier.pattern.x,
          vec2(f, y),
          cell,
          barrier.patternStyle.y
        ) *
        (1.0 - smoothstep(0.82, 1.0, y)) * twinkle;
  }
  float motif = motifValue * barrier.pattern.w * (0.45 + 0.55 * profile);
  if (barrier.proximity.z > 0.5) {
    motif *= 1.0 + barrier.patternMore.y * near.a;
  }
  vec3 motifColor = barrier.patternColor.a > 0.5
      ? barrier.patternColor.rgb
      : mix(barrier.footColor.rgb, vec3(1.0), 0.35);

  // The glint where the wall is seen edge-on.
  vec3 toViewer = barrier.viewer.w > 0.5
      ? barrier.viewer.xyz - fragWorldPosition
      : barrier.viewer.xyz;
  float viewLength = length(toViewer);
  toViewer = viewLength > 1e-6 ? toViewer / viewLength : vec3(0.0, 0.0, 1.0);
  float side = dot(normalize(fragNormal), toViewer);
  float glintValue = barrier.glint.x *
      pow(clamp(1.0 - abs(side), 0.0, 1.0), max(barrier.glint.y, 0.01)) *
      profile;
  // The near side of a closed wall (its outside faces the viewer) is thinned
  // so that it never veils what stands inside; the far side shows fully.
  float thin = 1.0 - clamp(barrier.extra.x, 0.0, 1.0) *
      smoothstep(0.0, max(barrier.extra.z, 1e-3), side);

  vec3 wall = tint * (body + glintValue + frontGlow) + motifColor * motif;
  if (barrier.pulse.a > 0.0) {
    wall += barrier.pulse.rgb * (0.3 + 0.7 * profile);
  }
  vec3 hits = impactClassic(barrier.impactPositions[0], barrier.impactColors[0]) +
      impactClassic(barrier.impactPositions[1], barrier.impactColors[1]) +
      impactClassic(barrier.impactPositions[2], barrier.impactColors[2]) +
      impactClassic(barrier.impactPositions[3], barrier.impactColors[3]);

  vec3 color = wall * thin + hits * (0.35 + 0.65 * profile) + near.rgb;
  color *= barrier.shape.z * mask * fragInstanceColor.rgb *
      fragInstanceColor.a;
  writeColor(color, 0.0);
}
