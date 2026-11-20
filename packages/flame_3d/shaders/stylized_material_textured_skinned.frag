#version 460 core

// Not drawn: StylizedMaterial pairs this bundle's vertex stage with the
// fragment stage of stylized_material_textured.frag. A stage this small keeps
// the bundle small.

out vec4 outColor;

void main() {
  outColor = vec4(0.0);
}
