#ifndef FLAME_INSTANCING_GLSL_
#define FLAME_INSTANCING_GLSL_

// Per-instance data that flame_3d feeds from an instance-rate vertex buffer:
// the four columns of the model matrix and a color (white unless the drawing
// component sets one). A vertex shader that declares the model columns is
// drawn instanced: the draws of one surface with the same material become a
// single draw.
//
// Like every vertex input, each of them must be used by the shader. A shader
// that does not need the color can declare the model columns by itself.
in vec4 instanceModel0;
in vec4 instanceModel1;
in vec4 instanceModel2;
in vec4 instanceModel3;
in vec4 instanceColor;

// The model matrix of the instance being drawn.
mat4 instanceModelMatrix() {
  return mat4(instanceModel0, instanceModel1, instanceModel2, instanceModel3);
}

#endif
