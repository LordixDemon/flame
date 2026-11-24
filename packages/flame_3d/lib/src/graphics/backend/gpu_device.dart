import 'package:flame_3d/src/graphics/backend/gpu_backend.dart';
import 'package:flame_3d/src/graphics/backend/gpu_enums.dart';

/// The graphics API a [GpuBackend] renders with.
enum GpuGraphicsApi() {
  /// Metal (iOS, macOS).
  metal,

  /// Vulkan (Android).
  vulkan,

  /// OpenGL ES (Android devices without a usable Vulkan driver, and the
  /// Android emulator).
  openGLES,

  /// WebGPU (browsers).
  webGPU,

  /// Not known, for instance in the software renderer of `flutter test`.
  unknown,
}

/// What the GPU device of a [GpuBackend] offers, as detected by
/// [GpuBackend.initialize]. See [GpuBackend.capabilities].
///
/// Flutter GPU reports a few capabilities itself (offscreen MSAA, hand-built
/// mipmaps, anisotropy); on OpenGL ES the backend also asks the driver for
/// its limits and extensions, and checks by rendering whether float textures
/// can be rendered into and sampled ([floatTextureTargets],
/// [halfFloatTextureTargets]). A limit that is `null` was not detected and is
/// not checked.
class const GpuDeviceCapabilities({
  /// The graphics API the backend renders with.
  final GpuGraphicsApi api = GpuGraphicsApi.unknown,

  /// The driver's description of the GPU (`GL_RENDERER` on OpenGL ES), when
  /// known.
  final String? renderer,

  /// The driver's vendor (`GL_VENDOR` on OpenGL ES), when known.
  final String? vendor,

  /// The API version the driver reports (`GL_VERSION` on OpenGL ES), when
  /// known.
  final String? version,

  /// The shading language version the driver reports
  /// (`GL_SHADING_LANGUAGE_VERSION` on OpenGL ES), when known.
  final String? shadingLanguageVersion,

  /// The driver's extensions (`GL_EXTENSIONS` on OpenGL ES), empty when not
  /// known.
  final Set<String> extensions = const {},

  /// Whether [extensions] was read from the driver.
  final bool extensionsKnown = false,

  /// The extensions that shaders of this device can require, found by
  /// compiling a shader that requires each extension the loaded shaders
  /// require (on OpenGL ES, where a driver may accept an extension it does
  /// not list, and the reverse).
  final Set<String> shaderExtensions = const {},

  /// Whether [shaderExtensions] was checked: when it is `false`, the
  /// extensions shaders require are not checked.
  final bool shaderExtensionsKnown = false,

  /// The number of uniform vectors (16 bytes each) a vertex shader may use
  /// (`GL_MAX_VERTEX_UNIFORM_VECTORS`), or `null` when not limited or not
  /// known.
  final int? maxVertexUniformVectors,

  /// The number of uniform vectors a fragment shader may use
  /// (`GL_MAX_FRAGMENT_UNIFORM_VECTORS`), or `null` when not limited or not
  /// known.
  final int? maxFragmentUniformVectors,

  /// The number of textures a vertex shader may sample
  /// (`GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS`), or `null` when not known.
  final int? maxVertexSamplers,

  /// The number of textures a fragment shader may sample
  /// (`GL_MAX_TEXTURE_IMAGE_UNITS`), or `null` when not known.
  final int? maxFragmentSamplers,

  /// The largest texture width and height (`GL_MAX_TEXTURE_SIZE`), or `null`
  /// when not known.
  final int? maxTextureSize,

  /// Whether a texture target can render into [GpuPixelFormat.r32Float] (and
  /// [GpuPixelFormat.rgbaFloat32]) textures that later passes sample.
  final bool floatTextureTargets = false,

  /// Whether a texture target can render into [GpuPixelFormat.rgbaFloat16]
  /// textures that later passes sample, keeping values above 1.
  final bool halfFloatTextureTargets = false,

  /// Whether render targets can be multisampled.
  final bool offscreenMsaa = false,

  /// Whether mip levels uploaded by hand sample correctly.
  final bool manualMipmaps = false,

  /// How the float targets were found: `'probe'` when rendered and read back
  /// on this device, `'api'` when the graphics API guarantees them,
  /// `'none'` when they were not looked for.
  final String floatTargetDetection = 'none',

  /// What the detection found along the way, by check (`deviceCheck`,
  /// `rgbaFloat16`, `r32Float`): `ok`, or why it failed.
  final Map<String, String> notes = const {},
}) {
  /// Capabilities of a backend that detected nothing: no limit is checked.
  static const GpuDeviceCapabilities unknown = GpuDeviceCapabilities();

  static final RegExp _glesVersionPattern = RegExp(
    r'OpenGL ES(?:-CM)?\s+(\d+)\.(\d+)',
  );

  /// Whether an OpenGL ES device reports OpenGL ES 3.0 or newer (`GL_VERSION`).
  bool get supportsOpenGlEs3 {
    if (api != GpuGraphicsApi.openGLES) {
      return false;
    }
    final v = version;
    if (v == null) {
      return false;
    }
    final match = _glesVersionPattern.firstMatch(v);
    if (match == null) {
      return false;
    }
    return (int.tryParse(match.group(1)!) ?? 0) >= 3;
  }

  /// Whether the driver reported [extension].
  bool hasExtension(String extension) => extensions.contains(extension);

  /// The capabilities as JSON-friendly values, for logs and device reports.
  Map<String, Object?> toJson() => {
    'api': api.name,
    'renderer': renderer,
    'vendor': vendor,
    'version': version,
    'shadingLanguageVersion': shadingLanguageVersion,
    'maxVertexUniformVectors': maxVertexUniformVectors,
    'maxFragmentUniformVectors': maxFragmentUniformVectors,
    'maxVertexSamplers': maxVertexSamplers,
    'maxFragmentSamplers': maxFragmentSamplers,
    'maxTextureSize': maxTextureSize,
    'floatTextureTargets': floatTextureTargets,
    'halfFloatTextureTargets': halfFloatTextureTargets,
    'floatTargetDetection': floatTargetDetection,
    'offscreenMsaa': offscreenMsaa,
    'manualMipmaps': manualMipmaps,
    'extensionsKnown': extensionsKnown,
    'shaderExtensionsKnown': shaderExtensionsKnown,
    'shaderExtensions': (shaderExtensions.toList()..sort()),
    'notes': notes,
    'extensions': (extensions.toList()..sort()),
  };

  @override
  String toString() =>
      'GpuDeviceCapabilities(${toJson()..remove('extensions')})';
}

/// The pipeline stage of a shader.
enum GpuShaderStage() {
  /// A vertex shader.
  vertex,

  /// A fragment shader.
  fragment,
}

/// What one shader of a shader bundle needs from the device, read from the
/// bundle (see [GpuBackend.shaderRequirements]).
class const GpuShaderRequirements({
  /// The shader's stage.
  required final GpuShaderStage stage,

  /// The uniform vectors (16 bytes each) the shader's uniform blocks occupy.
  required final int uniformVectors,

  /// The textures the shader samples.
  required final int samplers,

  /// The extensions the shader's source requires (`#extension ... : require`
  /// in its OpenGL ES build).
  final List<String> extensions = const [],
});

/// Whether a shader can run on the device of a [GpuBackend], see
/// [GpuBackend.shaderSupport].
class const GpuShaderSupport({
  /// What the shader needs.
  required final GpuShaderRequirements requirements,

  /// The extensions the shader requires that the device lacks.
  final List<String> missingExtensions = const [],

  /// The device's limit on [GpuShaderRequirements.uniformVectors] for the
  /// shader's stage, or `null` when not known.
  final int? uniformVectorLimit,

  /// The device's limit on [GpuShaderRequirements.samplers] for the shader's
  /// stage, or `null` when not known.
  final int? samplerLimit,
}) {
  /// Whether the shader needs more uniform vectors than the device has.
  bool get exceedsUniformVectors =>
      uniformVectorLimit != null &&
      requirements.uniformVectors > uniformVectorLimit!;

  /// Whether the shader samples more textures than the device allows.
  bool get exceedsSamplers =>
      samplerLimit != null && requirements.samplers > samplerLimit!;

  /// Whether the shader can run on the device.
  bool get isSupported =>
      missingExtensions.isEmpty && !exceedsUniformVectors && !exceedsSamplers;

  /// The reasons the shader cannot run, empty when it can.
  List<String> get problems {
    final stage = requirements.stage.name;
    final problems = [
      for (final extension in missingExtensions)
        'needs the extension $extension, which the device lacks',
    ];
    if (exceedsUniformVectors) {
      problems.add(
        'uses ${requirements.uniformVectors} uniform vectors in its $stage '
        'stage, the device allows $uniformVectorLimit',
      );
    }
    if (exceedsSamplers) {
      problems.add(
        'samples ${requirements.samplers} textures in its $stage stage, the '
        'device allows $samplerLimit',
      );
    }
    return problems;
  }
}

/// The state of the GPU device of a [GpuBackend], see
/// [GpuBackend.deviceState].
enum GpuDeviceState() {
  /// The device renders.
  ready,

  /// The device was lost: nothing is drawn until it is recovered.
  lost,

  /// The backend is rebuilding what it owns and checking the device.
  recovering,

  /// Recovery failed: nothing is drawn. The backend tries again the next
  /// time the app is resumed, or when [GpuBackend.recoverDevice] is called.
  failed,
}

/// Callbacks for the losses and recoveries of the GPU device, registered
/// with [GpuBackend.addDeviceListener].
class const GpuDeviceListener({
  /// Called when the device is found lost, with the reason.
  final void Function(Object reason)? onLost,

  /// Called once the device renders again, with the new
  /// [GpuBackend.deviceGeneration]: restore here what only the app can
  /// rebuild (textures that wrap `dart:ui` images, for instance).
  final void Function(int generation)? onRecovered,

  /// Called when recovery failed, with the error.
  final void Function(Object error)? onRecoveryFailed,
});
