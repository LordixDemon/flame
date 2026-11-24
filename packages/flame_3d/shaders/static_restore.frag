#version 460 core

in vec2 fragNdc;
in vec2 fragUv;

out vec4 outColor;

uniform sampler2D staticColorTexture;
uniform sampler2D staticDepthTexture;
uniform sampler2D shadowMap;
uniform sampler2D stillShadowMap;

uniform StaticRestore {
  mat4 invViewProjection;
  mat4 lightViewProjection;
  // x: zNear, y: zFar, z: 1.0 to project moving shadows else 0.0, w: unused.
  vec4 depthRange;
  // xyz: unit vector toward directional light.
  vec4 shadowToLight;
  // rgb: shadow tint, a: shadow strength.
  vec4 shadowColor;
  // xy: shadow map size, zw: inverse size.
  vec4 shadowMapSize;
  // x: texel world size, y: depth bias, z: normal bias, w: filter radius.
  vec4 shadowBias;
  // Depth decode dot-product weights.
  vec4 shadowDecode;
  // xy: moving shadow min UV, zw: max UV.
  vec4 movingBounds;
} restore;

float filterRadiusClamped(float value) {
  return clamp(floor(value), 0.0, 3.0);
}

void main() {
  vec4 col = texture(staticColorTexture, fragUv);
  vec4 dep = texture(staticDepthTexture, fragUv);
  vec3 bytes = floor(dep.rgb * 255.0 + 0.5);
  float clipZ = (bytes.r * 65536.0 + bytes.g * 256.0 + bytes.b) / 16777215.0;
  gl_FragDepth = mix(restore.depthRange.x, restore.depthRange.y, clipZ);

  if (restore.depthRange.z > 0.5 && dep.a > 0.002 && clipZ < 0.999999) {
    vec4 wp = restore.invViewProjection * vec4(fragNdc, clipZ, 1.0);
    vec3 worldPos = wp.xyz / wp.w;
    float radius = filterRadiusClamped(restore.shadowBias.w);
    float texel = restore.shadowBias.x;
    float reach = restore.shadowBias.y + restore.shadowBias.z * (1.0 + radius * 0.5);
    worldPos += restore.shadowToLight.xyz * (texel * reach);

    vec4 lc = restore.lightViewProjection * vec4(worldPos, 1.0);
    vec3 lndc = lc.xyz / lc.w;
    vec2 luv = vec2(0.5 + 0.5 * lndc.x, 0.5 - 0.5 * lndc.y);
    float ldepth = lndc.z;

    if (luv.x >= restore.movingBounds.x && luv.x <= restore.movingBounds.z &&
        luv.y >= restore.movingBounds.y && luv.y <= restore.movingBounds.w &&
        luv.x >= 0.0 && luv.x <= 1.0 &&
        luv.y >= 0.0 && luv.y <= 1.0 &&
        ldepth <= 1.0) {
      vec2 texelPos = luv * restore.shadowMapSize.xy - 0.5;
      vec2 base = floor(texelPos);
      vec2 f = texelPos - base;
      float stillLit = 0.0;
      float combLit = 0.0;
      int r = int(radius);
      for (int iy = -r; iy <= r + 1; iy++) {
        float y = float(iy);
        float wy = iy == -r ? (1.0 - f.y) : (iy == r + 1 ? f.y : 1.0);
        for (int ix = -r; ix <= r + 1; ix++) {
          float x = float(ix);
          float wx = ix == -r ? (1.0 - f.x) : (ix == r + 1 ? f.x : 1.0);
          float w = wx * wy;
          vec2 sampleUv = (base + vec2(x, y) + 0.5) * restore.shadowMapSize.zw;
          float storedStill =
            dot(texture(stillShadowMap, sampleUv), restore.shadowDecode);
          float storedComb =
            dot(texture(shadowMap, sampleUv), restore.shadowDecode);
          stillLit += w * step(ldepth, storedStill);
          combLit += w * step(ldepth, storedComb);
        }
      }
      float side = 2.0 * radius + 1.0;
      float norm = 1.0 / (side * side);
      float stillVis = stillLit * norm;
      float combVis = combLit * norm;
      if (combVis < stillVis - 1e-4) {
        vec3 sEff = mix(vec3(1.0), restore.shadowColor.rgb, restore.shadowColor.a);
        vec3 fStill = mix(sEff, vec3(1.0), stillVis);
        vec3 fComb = mix(sEff, vec3(1.0), combVis);
        float w = dep.a;
        vec3 denom = max(vec3(1.0 - w) + w * fStill, vec3(0.05));
        vec3 ratio = (vec3(1.0 - w) + w * fComb) / denom;
        col.rgb *= ratio;
      }
    }
  }
  outColor = col;
}
