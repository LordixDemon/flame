import 'dart:math' as math;
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// The skinned vertex stages read the joint matrices as their top three rows
// (flame_3d/skinning.glsl), which fits the 256 uniform vectors of an OpenGL
// ES 3.0 vertex shader. These tests draw skinned surfaces with the vertex
// stages of before, which read 64 whole matrices
// (test/gpu/shaders/reference/skinning_mat4.glsl), and with today's, and
// check that every pixel is the same.

const _width = 192;
const _height = 144;

/// A StylizedMaterial whose skinned and standard vertex stages read whole
/// joint matrices, as before.
class _Mat4StylizedMaterial() extends StylizedMaterial {
  final Shader _skinned = VertexShader.fromAsset(
    'test/stylized_skinned_mat4_reference.shaderbundle',
    slots: [
      RenderContext3D.cameraMatricesBlock,
      'Wind',
      RenderContext3D.jointMatricesBlock,
    ],
  );

  final Shader _standard = VertexShader.fromAsset(
    'test/stylized_standard_mat4_reference.shaderbundle',
    slots: [
      RenderContext3D.cameraMatricesBlock,
      RenderContext3D.jointMatricesBlock,
      'StylizedDepth',
    ],
  );

  @override
  Shader vertexShaderFor(VertexLayout layout) {
    final shader = super.vertexShaderFor(layout);
    if (identical(shader, vertexShader)) {
      return shader;
    }
    return layout.offsetOf(StylizedMaterial.masksAttribute) == null
        ? _standard
        : _skinned;
  }

  @override
  void apply(RenderContext context) {
    super.apply(context);
    _skinned
      ..setVector3('Wind.direction', windDirection)
      ..setVector3('Wind.modelDirection', Vector3.zero())
      ..setFloat('Wind.amplitude', windAmplitude)
      ..setVector3('Wind.phaseScale', windPhase)
      ..setFloat('Wind.frequency', windFrequency)
      ..setFloat('Wind.time', windTime)
      ..setVector3('Wind.upAxis', Vector3.zero())
      ..setVector3('Wind.gustWave', Vector3(0.5, 0, 0))
      ..setFloat('Wind.flutterFrequency', windFlutterFrequency)
      ..setFloat('Wind.gustFrequency', windGustFrequency);
    _standard.setFloat('StylizedDepth.bias', depthBias);
  }
}

/// A square tube along y, from -0.5 to 0.5, 0.2 wide, cut into 8 rings: the
/// lower rings follow joint 0, the upper ones joint 1, blended in between,
/// the top ring a quarter joint 2. Every vertex of one of the sides has
/// weights that add up to 0.8 rather than 1.
class _Tube() {
  this {
    const half = 0.1;
    const rings = 8;
    const sides = [
      ((0.0, 1.0), (-half, half), (half, half)),
      ((1.0, 0.0), (half, half), (half, -half)),
      ((0.0, -1.0), (half, -half), (-half, -half)),
      ((-1.0, 0.0), (-half, -half), (-half, half)),
    ];
    for (final (side, ((nx, nz), (ax, az), (bx, bz))) in sides.indexed) {
      final first = positions.length ~/ 3;
      for (var r = 0; r < rings; r++) {
        final y = -0.5 + r / (rings - 1);
        positions.addAll([ax, y, az, bx, y, bz]);
        normals.addAll([nx, 0, nz, nx, 0, nz]);
        final up = ((y + 0.2) / 0.4).clamp(0.0, 1.0);
        final top = r == rings - 1 ? 0.25 : 0.0;
        final scale = side == 3 ? 0.8 : 1.0;
        for (var k = 0; k < 2; k++) {
          joints.addAll([0, 1, 2, 3]);
          weights.addAll([
            (1 - up) * scale,
            (up - top) * scale * 0.9,
            top * scale,
            (up - top) * scale * 0.1,
          ]);
          final shade = 0.4 + 0.5 * r / (rings - 1);
          colors.addAll([shade, 0.55, 1 - shade, 1]);
        }
      }
      for (var r = 0; r + 1 < rings; r++) {
        final a = first + r * 2;
        indices.addAll([a, a + 1, a + 3, a + 3, a + 2, a]);
      }
    }
  }

  final List<double> positions = [];
  final List<double> normals = [];
  final List<double> colors = [];
  final List<double> joints = [];
  final List<double> weights = [];
  final List<int> indices = [];

  int get vertexCount => positions.length ~/ 3;

  /// The tube in StylizedMaterial's skinned layout.
  Surface stylized(Material material) => StylizedMaterial.buildSurface(
    positions: positions,
    normals: normals,
    colors: colors,
    gloss: List.filled(vertexCount, 0.5),
    tint: [
      for (var v = 0; v < vertexCount; v++)
        if (v.isEven) 1.0 else 0.0,
    ],
    sway: [for (var v = 0; v < vertexCount; v++) positions[v * 3 + 1] + 0.5],
    joints: joints,
    weights: weights,
    indices: indices,
    material: material,
  );

  /// The tube in the standard layout.
  Surface standard(Material material) => Surface(
    vertices: [
      for (var v = 0; v < vertexCount; v++)
        Vertex(
          position: Vector3(
            positions[v * 3],
            positions[v * 3 + 1],
            positions[v * 3 + 2],
          ),
          texCoord: Vector2.zero(),
          color: Color.from(
            alpha: 1,
            red: colors[v * 4],
            green: colors[v * 4 + 1],
            blue: colors[v * 4 + 2],
          ),
          normal: Vector3(
            normals[v * 3],
            normals[v * 3 + 1],
            normals[v * 3 + 2],
          ),
          joints: Vector4.array(joints, v * 4),
          weights: Vector4.array(weights, v * 4),
        ),
    ],
    indices: indices,
    material: material,
  );
}

/// Joint matrices that turn, scale (unevenly too) and move.
List<Matrix4> _poses(int i) => [
  Matrix4.identity(),
  Matrix4.translationValues(0.05 * i, 0.4, 0.1)
    ..rotateZ(-0.35 - 0.1 * i)
    ..rotateX(0.2)
    ..translateByDouble(0, -0.4, 0, 1),
  Matrix4.translationValues(-0.1, 0.05 * i, 0)
    ..scaleByDouble(1.3, 0.7 + 0.1 * i, 1.1, 1),
  Matrix4.translationValues(0.2, -0.1, 0.05)
    ..rotateY(0.6 * i)
    ..scaleByDouble(0.8, 1, 1.25, 1),
];

List<Light> _lights() => [
  Light(
    position: Vector3.zero(),
    source: HemisphereLight(
      skyColor: const Color(0xFFB4CCF0),
      groundColor: const Color(0xFF6E7A50),
      intensity: 0.6,
    ),
  ),
  Light(
    position: Vector3.zero(),
    source: DirectionalLight(
      direction: Vector3(0.4, -0.5, -0.8),
      intensity: 0.8,
    ),
  ),
];

/// Draws rows of skinned tubes: in StylizedMaterial's skinned layout, in the
/// standard layout with a StylizedMaterial and with an UnlitMaterial. With
/// [reference], their vertex stages read whole joint matrices, as before.
Future<Pixels> _render({required bool reference}) async {
  final stylized = reference ? _Mat4StylizedMaterial() : StylizedMaterial();
  stylized
    ..windTime = 1.3
    ..windAmplitude = 0.05;
  final unlit = UnlitMaterial(albedoColor: const Color(0xFFE0C080));
  if (reference) {
    unlit.vertexShader = VertexShader.fromAsset(
      'test/unlit_mat4_reference.shaderbundle',
      slots: [
        RenderContext3D.cameraMatricesBlock,
        RenderContext3D.jointMatricesBlock,
      ],
    );
  }
  final tube = _Tube();
  final own = tube.stylized(stylized);
  final standard = tube.standard(stylized);
  final plain = tube.standard(unlit);

  final frame = await renderFrame(
    width: _width,
    height: _height,
    lights: _lights(),
    draw: (context) {
      for (var i = 0; i < 5; i++) {
        final x = -0.8 + i * 0.4;
        Matrix4 at(double y) => Matrix4.translationValues(x, y, -5)
          ..rotateY(0.3 * i - 0.6)
          ..rotateX(0.15 * i);
        context
          ..drawSurface(
            own,
            transform: at(0.55),
            color: const Color(0xFFE07040),
            jointTransforms: _poses(i),
          )
          ..drawSurface(
            standard,
            transform: at(0),
            color: const Color(0xFF40A0E0),
            jointTransforms: _poses(i + 1),
          )
          ..drawSurface(
            plain,
            transform: at(-0.55)..rotateZ(math.pi / 9),
            jointTransforms: _poses(4 - i),
          );
      }
    },
  );
  return frame.pixels;
}

void main() {
  setUpGpu();

  setUpAll(() async {
    if (gpuAvailable) {
      await registerTestShaders([
        'stylized_skinned_mat4_reference',
        'stylized_standard_mat4_reference',
        'unlit_mat4_reference',
      ]);
    }
  });

  testGpuEngine('joint matrices as three rows render the same pixels as '
      'whole matrices', () async {
    final reference = await _render(reference: true);
    final pixels = await _render(reference: false);

    // The tubes are drawn, bent by their joints.
    expect(reference.count((r, g, b, a) => a > 0), greaterThan(4000));
    expect(differingPixels(pixels, reference, tolerance: 0), 0);
  });
}
