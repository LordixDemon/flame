#ifndef BARRIER_MATERIAL_SHARED_GLSL_
#define BARRIER_MATERIAL_SHARED_GLSL_

// The inputs, the uniform block and the functions of the two fragment
// variants of `BarrierMaterial`: `barrier_material.frag`, the lean variant
// drawn while every option that needs more is off, and
// `barrier_material_full.frag`, drawn when one is on and for the reaction in
// front. A function neither calls is left out of its build.
//
// Written for GLSL ES 1.00 too (the OpenGL ES backend): no flat inputs, no
// explicit texture LOD, no derivatives, no switch, no integer operations, no
// loops; the impacts, their rings and the near points are unrolled with
// constant indices, each behind a branch on a uniform. Every value that grows
// with time (the pattern offsets, the twinkle phase, the noise offset, the age
// of each impact, the pulse and the flicker) is computed and wrapped by
// `BarrierMaterial` on the CPU.
//
// The normal points out of the enclosed area: the side of the wall whose
// outside faces the viewer is the near side.

in vec3 fragWorldPosition;
in vec3 fragNormal;
in vec2 fragWall;
in vec4 fragInstanceColor;
// x: the height above the foot in world units, y: the wobble of the surface,
// from -1 to 1 times the strength of the impacts.
in vec2 fragDetail;

out vec4 outColor;

uniform BarrierLook {
  vec4 footColor;
  vec4 topColor;
  // x: appear factor, y: height falloff exponent, z: intensity, w: foot glow.
  vec4 shape;
  // x: motif (0 plain, 1 chevrons, 2 diamonds, 3 dashes, 4 hexagons, 5 grid),
  // y: motifs per scene unit, z: offset of the pattern in motifs, w: pattern
  // strength.
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
  // xyz: world position, w: age in seconds. The active impacts come first.
  vec4 impactPositions[8];
  // rgb: color, a: strength (0 for an unused slot).
  vec4 impactColors[8];
  // x: how much the side of the wall facing the viewer is thinned, y: how
  // much the side whose inside faces the viewer is, z: the facing (cosine)
  // over which they thin, w: the number of active impacts.
  vec4 extra;
  // x: fade start, y: 1 / (fade end - fade start), z: 1 when the fade is
  // remapped, w: the flicker multiplier of the wall's light.
  vec4 profile;
  // rgb: the top edge's color times its strength, a: 1 / its width (0 off).
  vec4 topEdge;
  // rgb: fill color, a: fill opacity (0 off).
  vec4 fill;
  // x: how much the fill follows the fade, y: 1 to preserve the hue, z: 1
  // when any light of `profile.w`, `topEdge`, `pulse`, `noise` or the
  // wobble's shading is on, w: the reaction-only scale (0: the whole wall).
  vec4 mode;
  // x: motif rows, y: line width multiplier, z: twinkle depth, w: offset of
  // the rows in rows.
  vec4 patternStyle;
  // rgb: motif color, a: 1 to use it instead of the foot color lightened.
  vec4 patternColor;
  // x: 1 to fade the band's foot as well (rising motifs), y: how much near
  // points brighten the motifs, z: the wobble's shading, w: unused.
  vec4 patternMore;
  // x: strength (0 off), y: cells per unit along, z: cells per unit up, w:
  // offset up in cells.
  vec4 noise;
  // x: the cells after which the noise repeats along the wall, yzw: unused.
  vec4 noiseExtra;
  // x: rings per impact, y: seconds between rings, z: ring strength, w: the
  // distance where the rings have faded out (0: no limit).
  vec4 rings;
  // x: flash strength, y: 1 / the flash's share of the impact duration, zw:
  // unused.
  vec4 flash;
  // rgb: pulse color times its value, a: its value.
  vec4 pulse;
  // x: radius of a near point's glow, y: its strength, z: the number of
  // active near points, w: unused.
  vec4 proximity;
  // xyz: world position, w: strength. The active points come first.
  vec4 nearPositions[4];
  // rgb: color, a: unused.
  vec4 nearColors[4];
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

// A hash of a 2D cell without sine, steady at mediump.
float hash2(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Value noise from 0 to 1, repeating every [period] cells along x and every
// 256 cells along y.
float valueNoise(vec2 p, float period) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float x0 = mod(i.x, period);
  float x1 = mod(i.x + 1.0, period);
  float y0 = mod(i.y, 256.0);
  float y1 = mod(i.y + 1.0, 256.0);
  float a = hash2(vec2(x0, y0));
  float b = hash2(vec2(x1, y0));
  float c = hash2(vec2(x0, y1));
  float d = hash2(vec2(x1, y1));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// A chevron pointing along +x in the motif cell `p` (both in 0..1).
float chevron(vec2 p, float w) {
  vec2 q = vec2(p.x, abs(p.y - 0.5));
  return glow(segmentDistance(q, vec2(0.6, 0.0), vec2(0.4, 0.24)), 0.065 * w);
}

// A diamond outline with a dot at its center.
float diamond(vec2 p, float w) {
  vec2 q = abs(p - vec2(0.5));
  float outline = glow(abs(q.x + q.y * 0.6 - 0.2), 0.055 * w);
  float center = glow(length(q * vec2(1.0, 0.6)), 0.045 * w);
  return max(outline, center);
}

// Rune-like dashes: a stem of varying length with a dot, a caret or a bar,
// different from motif to motif.
float dashes(vec2 p, float cell, float w) {
  float h1 = hash(cell);
  float h2 = hash(cell + 17.0);
  float h3 = hash(cell + 31.0);
  float x = 0.5 + (h3 - 0.5) * 0.24;
  float top = 0.4 + 0.42 * h1;
  float value = glow(
    segmentDistance(p, vec2(x, 0.12), vec2(x, top)),
    0.07 * w
  );
  if (h2 < 0.34) {
    value = max(value, glow(length(p - vec2(x, top + 0.13)), 0.07 * w));
  } else if (h2 < 0.67) {
    vec2 tip = vec2(x, top + 0.1);
    value = max(
      value,
      max(
        glow(segmentDistance(p, tip, tip + vec2(-0.13, -0.13)), 0.06 * w),
        glow(segmentDistance(p, tip, tip + vec2(0.13, -0.13)), 0.06 * w)
      )
    );
  } else {
    float mid = 0.12 + (top - 0.12) * 0.6;
    value = max(
      value,
      glow(
        segmentDistance(p, vec2(x - 0.14, mid), vec2(x + 0.14, mid)),
        0.06 * w
      )
    );
  }
  return value;
}

// The outlines of a honeycomb of pointy-topped hexagons, one per motif along
// the wall and one per row up it, every other row shifted by half a motif:
// `p` is (motifs along, rows up).
float hexagons(vec2 p, float w) {
  vec2 r = vec2(1.0, 1.7320508);
  vec2 h = r * 0.5;
  vec2 uv = vec2(p.x, p.y * 0.8660254);
  vec2 a = mod(uv, r) - h;
  vec2 b = mod(uv - h, r) - h;
  vec2 g = dot(a, a) < dot(b, b) ? a : b;
  vec2 q = abs(g);
  float d = max(q.x, dot(q, vec2(0.5, 0.8660254)));
  return glow(abs(0.5 - d), 0.05 * w);
}

// A cage: a bar up the middle of each motif and a rung across each row's
// boundary, in the cell `p`.
float grid(vec2 p, float w) {
  float bar = glow(abs(p.x - 0.5), 0.06 * w);
  float rung = glow(min(p.y, 1.0 - p.y), 0.06 * w);
  return max(bar, rung);
}

// The motif [motif] in the cell `p` (both 0..1) of number [cell], or at
// `lattice` (motifs along, rows up) for the motifs that span cells.
float motifAt(float motif, vec2 p, float cell, vec2 lattice, float w) {
  if (motif < 0.5) {
    return 0.0;
  } else if (motif < 1.5) {
    return chevron(p, w);
  } else if (motif < 2.5) {
    return diamond(p, w);
  } else if (motif < 3.5) {
    return dashes(p, cell, w);
  } else if (motif < 4.5) {
    return hexagons(lattice, w);
  }
  return grid(p, w);
}

// The brightness of ring [k] of an impact of age [age], at a distance [d]
// from it: the rings leave the point `rings.y` seconds apart, each 0.7 times
// as bright as the one before, and fade out towards the reach of `rings.w`.
float ringAt(float k, float d, float age, float width) {
  float radius = (age - k * barrier.rings.y) * barrier.impactShape.x;
  float r = (d - radius) / width;
  float value = exp(-r * r);
  if (k > 0.5) {
    value *= pow(0.7, k);
  }
  if (barrier.rings.w > 0.0) {
    value *= 1.0 - smoothstep(barrier.rings.w * 0.6, barrier.rings.w, radius);
  }
  return value;
}

// The light of one impact at this fragment: rings spreading from it and a
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
  // The rings that have left the point, the outermost first: only the two
  // around this fragment light it.
  float interval = max(barrier.rings.y, 1e-4);
  float last = min(barrier.rings.x - 1.0, floor(age / interval));
  float spacing = max(interval * barrier.impactShape.x, 1e-4);
  float k = clamp(
    floor((age * barrier.impactShape.x - d) / spacing),
    0.0,
    max(last, 0.0)
  );
  float ring = ringAt(k, d, age, width);
  if (k + 1.0 <= last) {
    ring += ringAt(k + 1.0, d, age, width);
  }
  float fade = (1.0 - life) * (1.0 - life) * barrier.rings.z;
  ring = ring * fade;
  float flashRadius = max(barrier.impactShape.w, 1e-4);
  float flashFade = max(1.0 - life * barrier.flash.y, 0.0);
  float flash = exp(-(d * d) / (flashRadius * flashRadius)) *
      flashFade * flashFade;
  return colorStrength.rgb * (colorStrength.a * (ring + flash * barrier.flash.x));
}

// The sum of the active impacts' light.
vec3 impacts() {
  float count = barrier.extra.w;
  vec3 sum = vec3(0.0);
  if (count > 0.5) {
    sum = impact(barrier.impactPositions[0], barrier.impactColors[0]);
  }
  if (count > 1.5) {
    sum = sum + impact(barrier.impactPositions[1], barrier.impactColors[1]);
  }
  if (count > 2.5) {
    sum = sum + impact(barrier.impactPositions[2], barrier.impactColors[2]);
  }
  if (count > 3.5) {
    sum = sum + impact(barrier.impactPositions[3], barrier.impactColors[3]);
  }
  if (count > 4.5) {
    sum = sum + impact(barrier.impactPositions[4], barrier.impactColors[4]);
  }
  if (count > 5.5) {
    sum = sum + impact(barrier.impactPositions[5], barrier.impactColors[5]);
  }
  if (count > 6.5) {
    sum = sum + impact(barrier.impactPositions[6], barrier.impactColors[6]);
  }
  if (count > 7.5) {
    sum = sum + impact(barrier.impactPositions[7], barrier.impactColors[7]);
  }
  return sum;
}

// How close the near point [positionStrength] is to this fragment, from 0
// (beyond the radius) to its strength (on it).
float nearness(vec4 positionStrength) {
  float d = distance(fragWorldPosition, positionStrength.xyz);
  float k = clamp(1.0 - d / max(barrier.proximity.x, 1e-4), 0.0, 1.0);
  return positionStrength.w * k * k;
}

// The glow of the near points (rgb) and how near the nearest is (a).
vec4 nearGlow() {
  float count = barrier.proximity.z;
  vec4 sum = vec4(0.0);
  if (count > 0.5) {
    float k = nearness(barrier.nearPositions[0]);
    sum += vec4(barrier.nearColors[0].rgb * k, k);
  }
  if (count > 1.5) {
    float k = nearness(barrier.nearPositions[1]);
    sum += vec4(barrier.nearColors[1].rgb * k, k);
  }
  if (count > 2.5) {
    float k = nearness(barrier.nearPositions[2]);
    sum += vec4(barrier.nearColors[2].rgb * k, k);
  }
  if (count > 3.5) {
    float k = nearness(barrier.nearPositions[3]);
    sum += vec4(barrier.nearColors[3].rgb * k, k);
  }
  return vec4(sum.rgb * barrier.proximity.y, sum.a);
}

// Scales [color] down to keep its hue where its brightest channel goes above
// 0.8, so that it reaches 1 smoothly instead of clipping channel by channel.
// It is applied to the wall's own light and fill, not to the reaction.
vec3 keepHue(vec3 color) {
  float m = max(color.r, max(color.g, color.b));
  if (m <= 0.8) {
    return color;
  }
  float compressed = 0.8 + 0.2 * (1.0 - exp(-(m - 0.8) / 0.2));
  return color * (compressed / m);
}

// Writes [color] (premultiplied) with an alpha of its brightest channel or
// [cover], whichever is larger.
void writeColor(vec3 color, float cover) {
  color = max(color, vec3(0.0));
  float alpha = clamp(max(color.r, max(color.g, color.b)), 0.0, 1.0);
  if (cover > 0.0) {
    alpha = clamp(max(alpha, cover), 0.0, 1.0);
  }
  if (barrier.glint.z > 0.5) {
    outColor = vec4(color, alpha);
  } else {
    outColor = vec4(color / max(alpha, 1e-4), alpha);
  }
}

// How much of what is behind the wall its fill covers: the fill opacity,
// following the fade by `mode.x`, raised by the pulse, thinned like the wall.
// The noise breaks up the light over the fill, not the fill itself, so that
// a dense wall neither opens holes onto what is behind it nor darkens in
// patches.
float fillCover(float profile, float thin, float mask) {
  return barrier.fill.a * mix(1.0, profile, barrier.mode.x) *
      (1.0 + barrier.pulse.a) * thin * mask * fragInstanceColor.a;
}

// The motifs of the lean variant: no motif spans cells there.
float motifAtClassic(float motif, vec2 p, float cell, float w) {
  if (motif < 0.5) {
    return 0.0;
  } else if (motif < 1.5) {
    return chevron(p, w);
  } else if (motif < 2.5) {
    return diamond(p, w);
  }
  return dashes(p, cell, w);
}

// The light of one impact of the lean variant: one ring spreading from it,
// with no reach, and a flash around it.
vec3 impactClassic(vec4 positionAge, vec4 colorStrength) {
  float age = positionAge.w;
  float duration = max(barrier.impactShape.z, 1e-3);
  if (colorStrength.a <= 0.0 || age < 0.0 || age >= duration) {
    return vec3(0.0);
  }
  float life = age / duration;
  float d = distance(fragWorldPosition, positionAge.xyz);
  float width = max(barrier.impactShape.y, 1e-4);
  float r = (d - age * barrier.impactShape.x) / width;
  float fade = (1.0 - life) * (1.0 - life) * barrier.rings.z;
  float ring = exp(-r * r) * fade;
  float flashRadius = max(barrier.impactShape.w, 1e-4);
  float flashFade = max(1.0 - life * barrier.flash.y, 0.0);
  float flash = exp(-(d * d) / (flashRadius * flashRadius)) *
      flashFade * flashFade;
  return colorStrength.rgb * (colorStrength.a * (ring + flash * barrier.flash.x));
}

#endif
