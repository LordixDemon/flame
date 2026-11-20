#version 460 core

// A translucent energy wall (`BarrierMaterial`): brightest at its foot and
// thinner above, rising from the foot with the appear factor, with a slow
// procedural pattern travelling along it, a glint where it is seen edge-on and
// up to four impacts, each a ring spreading over the wall and a local flash.
//
// Written for GLSL ES 1.00 too (the OpenGL ES backend): no flat inputs, no
// explicit texture LOD, no derivatives, no switch, no integer operations, no
// loops; the four impacts are unrolled with constant indices. Every value that
// grows with time (the pattern offset, the twinkle phase, the age of each
// impact) is computed and wrapped by `BarrierMaterial` on the CPU.
//
// The normal points out of the enclosed area: the side of the wall whose
// outside faces the viewer is the near side.
//
// The output is premultiplied (`glint.z` > 0.5) or straight, with an alpha of
// the brightest channel: added as it is by additive blending, which keeps the
// target's alpha, or laid over the target by alpha blending.

in vec3 fragWorldPosition;
in vec3 fragNormal;
in vec2 fragWall;
in vec4 fragInstanceColor;

out vec4 outColor;

uniform BarrierLook {
  vec4 footColor;
  vec4 topColor;
  // x: appear factor, y: height falloff exponent, z: intensity, w: foot glow.
  vec4 shape;
  // x: motif (0 plain, 1 chevrons, 2 diamonds, 3 dashes), y: motifs per
  // scene unit, z: offset of the pattern in motifs, w: pattern strength.
  vec4 pattern;
  // x: height of the band the motifs fill (0..1 of the wall), y: the number
  // of motifs after which the pattern repeats, z: +1 or -1, the direction the
  // pattern travels, w: twinkle phase in radians.
  vec4 patternExtra;
  // x: glint strength, y: glint power, z: 1 for premultiplied output, w: the
  // softness of the rising front.
  vec4 glint;
  // xyz: unit vector towards the viewer (w = 0) or the eye position (w = 1).
  vec4 viewer;
  // x: ring speed (units per second), y: ring width (units), z: impact
  // duration (seconds), w: flash radius (units).
  vec4 impactShape;
  // xyz: world position, w: age in seconds.
  vec4 impactPositions[4];
  // rgb: color, a: strength (0 for an unused slot).
  vec4 impactColors[4];
  // x: how much the side of the wall facing the viewer is thinned.
  vec4 extra;
} barrier;

float segmentDistance(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a;
  vec2 ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

// A soft luminous stroke: a core of about [width] and a faint halo.
float glow(float d, float width) {
  float core = 1.0 - smoothstep(width * 0.5, width, d);
  float halo = exp(-(d * d) / (width * width * 4.0));
  return max(core, halo * 0.3);
}

float hash(float n) {
  return fract(sin(n * 12.9898 + 78.233) * 43758.5453);
}

// A chevron pointing along +x in the motif cell `p` (both in 0..1).
float chevron(vec2 p) {
  vec2 q = vec2(p.x, abs(p.y - 0.5));
  return glow(segmentDistance(q, vec2(0.6, 0.0), vec2(0.4, 0.24)), 0.065);
}

// A diamond outline with a dot at its center.
float diamond(vec2 p) {
  vec2 q = abs(p - vec2(0.5));
  float outline = glow(abs(q.x + q.y * 0.6 - 0.2), 0.055);
  float center = glow(length(q * vec2(1.0, 0.6)), 0.045);
  return max(outline, center);
}

// Rune-like dashes: a stem of varying length with a dot, a caret or a bar,
// different from motif to motif.
float dashes(vec2 p, float cell) {
  float h1 = hash(cell);
  float h2 = hash(cell + 17.0);
  float h3 = hash(cell + 31.0);
  float x = 0.5 + (h3 - 0.5) * 0.24;
  float top = 0.4 + 0.42 * h1;
  float value = glow(segmentDistance(p, vec2(x, 0.12), vec2(x, top)), 0.07);
  if (h2 < 0.34) {
    value = max(value, glow(length(p - vec2(x, top + 0.13)), 0.07));
  } else if (h2 < 0.67) {
    vec2 tip = vec2(x, top + 0.1);
    value = max(
      value,
      max(
        glow(segmentDistance(p, tip, tip + vec2(-0.13, -0.13)), 0.06),
        glow(segmentDistance(p, tip, tip + vec2(0.13, -0.13)), 0.06)
      )
    );
  } else {
    float mid = 0.12 + (top - 0.12) * 0.6;
    value = max(
      value,
      glow(segmentDistance(p, vec2(x - 0.14, mid), vec2(x + 0.14, mid)), 0.06)
    );
  }
  return value;
}

float motifAt(float motif, vec2 p, float cell) {
  if (motif < 0.5) {
    return 0.0;
  } else if (motif < 1.5) {
    return chevron(p);
  } else if (motif < 2.5) {
    return diamond(p);
  }
  return dashes(p, cell);
}

// The light of one impact at this fragment: a ring spreading from it and a
// flash around it, fading out over the impact's duration.
vec3 impact(vec4 positionAge, vec4 colorStrength) {
  float age = positionAge.w;
  float duration = max(barrier.impactShape.z, 1e-3);
  if (colorStrength.a <= 0.0 || age < 0.0 || age >= duration) {
    return vec3(0.0);
  }
  float life = age / duration;
  float d = distance(fragWorldPosition, positionAge.xyz);
  float width = max(barrier.impactShape.y, 1e-4);
  float r = (d - age * barrier.impactShape.x) / width;
  float fade = (1.0 - life) * (1.0 - life);
  float ring = exp(-r * r) * fade;
  float flashRadius = max(barrier.impactShape.w, 1e-4);
  float flashFade = max(1.0 - life * 3.0, 0.0);
  float flash = exp(-(d * d) / (flashRadius * flashRadius)) *
      flashFade * flashFade;
  return colorStrength.rgb * (colorStrength.a * (ring + flash * 0.8));
}

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
    float twinkle = 0.75 +
        0.25 * sin(barrier.patternExtra.w + hash(cell + 5.0) * 6.2831853);
    motifValue = motifAt(barrier.pattern.x, vec2(f, y), cell) *
        (1.0 - smoothstep(0.82, 1.0, y)) * twinkle;
  }
  float motif = motifValue * barrier.pattern.w * (0.45 + 0.55 * profile);
  vec3 motifColor = mix(barrier.footColor.rgb, vec3(1.0), 0.35);

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
  float near = 1.0 - clamp(barrier.extra.x, 0.0, 1.0) *
      smoothstep(0.0, 0.45, side);

  vec3 impacts = impact(barrier.impactPositions[0], barrier.impactColors[0]) +
      impact(barrier.impactPositions[1], barrier.impactColors[1]) +
      impact(barrier.impactPositions[2], barrier.impactColors[2]) +
      impact(barrier.impactPositions[3], barrier.impactColors[3]);

  vec3 color = (tint * (body + glintValue + frontGlow) + motifColor * motif) *
      near + impacts * (0.35 + 0.65 * profile);
  color *= barrier.shape.z * mask * fragInstanceColor.rgb *
      fragInstanceColor.a;
  color = max(color, vec3(0.0));

  float alpha = clamp(max(color.r, max(color.g, color.b)), 0.0, 1.0);
  if (barrier.glint.z > 0.5) {
    outColor = vec4(color, alpha);
  } else {
    outColor = vec4(color / max(alpha, 1e-4), alpha);
  }
}
