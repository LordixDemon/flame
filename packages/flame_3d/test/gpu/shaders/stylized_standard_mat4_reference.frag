#version 460 core

// Not used: the reference vertex stage draws with the material's own
// fragment stage.

out vec4 outColor;

void main() {
  outColor = vec4(1.0);
}
