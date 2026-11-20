import 'dart:convert';
import 'dart:typed_data';

import 'package:flame_3d/src/graphics/backend/gpu_device.dart';
import 'package:flame_3d/src/graphics/backend/gpu_handles.dart';

/// Reads the vertex inputs of every shader in an `impellerc` shader bundle.
///
/// Flutter GPU binds vertex attributes by input name but does not expose the
/// inputs a shader declares. They are needed to build a vertex layout that
/// feeds exactly those inputs, so they are read from the bundle itself: a
/// flatbuffer (`impeller/shader_bundle/shader_bundle.fbs`, file identifier
/// `IPSB`) holding, for each shader and backend, the reflected inputs.
///
/// Returns a map from shader name (the bundle's entry point key) to its inputs
/// ordered by location, or `null` when [bytes] is not a shader bundle this
/// reader understands.
Map<String, List<GpuShaderInput>>? reflectShaderBundleInputs(ByteData bytes) {
  try {
    return _FlatBufferReader(bytes)._readBundle();
    // The bundle format is private to the engine: anything unexpected means
    // reflection is unavailable rather than an error.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return null;
  }
}

/// Reads what every shader of an `impellerc` shader bundle needs from an
/// OpenGL ES device, from the bundle's OpenGL ES build: the uniform vectors
/// its uniform blocks and loose uniforms occupy, the textures it samples and
/// the extensions its source requires.
///
/// Returns a map from shader name to its requirements (shaders without an
/// OpenGL ES build are left out), or `null` when [bytes] is not a shader
/// bundle this reader understands.
Map<String, GpuShaderRequirements>? reflectShaderBundleGlesRequirements(
  ByteData bytes,
) {
  try {
    return _FlatBufferReader(bytes)._readGlesRequirements();
    // The bundle format is private to the engine: anything unexpected means
    // reflection is unavailable rather than an error.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return null;
  }
}

/// The uniform vectors the loose (non-block, non-sampler) uniforms declared
/// in the GLSL ES [source] occupy, such as the `_impeller_y_flip` float the
/// shader compiler adds: one per vector or scalar, one per column of a
/// matrix, times the length of an array.
int looseUniformVectors(String source) {
  var vectors = 0;
  for (final match in _looseUniform.allMatches(source)) {
    final type = match.group(1)!;
    final count = int.parse(match.group(2) ?? '1');
    vectors += count * (type.startsWith('mat') ? int.parse(type[3]) : 1);
  }
  return vectors;
}

/// The extensions the GLSL [source] requires (`#extension NAME : require`).
List<String> requiredExtensions(String source) => [
  for (final match in _requiredExtension.allMatches(source)) match.group(1)!,
];

final RegExp _looseUniform = RegExp(
  r'^\s*uniform\s+(?:(?:highp|mediump|lowp)\s+)?'
  r'(float|vec[234]|mat[234]|int|ivec[234]|bool|bvec[234])\s+\w+'
  r'(?:\s*\[\s*(\d+)\s*\])?\s*;',
  multiLine: true,
);

final RegExp _requiredExtension = RegExp(
  r'^\s*#\s*extension\s+(\w+)\s*:\s*require',
  multiLine: true,
);

class _FlatBufferReader(final ByteData _data) {
  // Field indices, in declaration order of the schema.
  static const _bundleShaders = 0;
  static const _shaderName = 0;
  // `vulkan`, `metal_desktop`, `metal_ios`, `opengl_es`, `opengl_desktop`.
  static const _shaderBackends = [5, 2, 1, 3, 4];
  static const _openGlEsBackend = 3;
  static const _backendStage = 0;
  static const _backendInputs = 2;
  static const _backendUniformStructs = 3;
  static const _backendUniformTextures = 4;
  static const _backendSource = 5;
  static const _structSize = 4;
  // `ShaderStage.kVertex`.
  static const _vertexStage = 0;
  static const _inputName = 0;
  static const _inputLocation = 1;
  static const _inputType = 4;
  static const _inputVecSize = 6;
  static const _inputColumns = 7;

  // `InputDataType.kFloat`.
  static const _floatType = 9;

  Map<String, List<GpuShaderInput>>? _readBundle() {
    if (_data.lengthInBytes < 8 ||
        String.fromCharCodes([
              for (var i = 4; i < 8; i++) _data.getUint8(i),
            ]) !=
            'IPSB') {
      return null;
    }
    final root = _u32(0);
    final result = <String, List<GpuShaderInput>>{};
    for (final shader in _tables(root, _bundleShaders)) {
      final name = _string(shader, _shaderName);
      if (name == null) {
        continue;
      }
      // Every backend reflects the same inputs, use the first one present.
      for (final index in _shaderBackends) {
        final backend = _table(shader, index);
        if (backend == null) {
          continue;
        }
        final inputs = <GpuShaderInput>[];
        for (final input in _tables(backend, _backendInputs)) {
          final inputName = _string(input, _inputName);
          if (inputName == null) {
            return null;
          }
          final type = _scalar32(input, _inputType);
          final columns = _scalar64(input, _inputColumns, fallback: 1);
          inputs.add(
            GpuShaderInput(
              name: inputName,
              location: _scalar64(input, _inputLocation),
              // Non-float and matrix inputs cannot be fed by a float layout;
              // a component count of 0 marks them as such.
              components: type == _floatType && columns <= 1
                  ? _scalar64(input, _inputVecSize)
                  : 0,
            ),
          );
        }
        inputs.sort((a, b) => a.location.compareTo(b.location));
        result[name] = inputs;
        break;
      }
    }
    return result;
  }

  Map<String, GpuShaderRequirements>? _readGlesRequirements() {
    if (!_isBundle()) {
      return null;
    }
    final result = <String, GpuShaderRequirements>{};
    for (final shader in _tables(_u32(0), _bundleShaders)) {
      final name = _string(shader, _shaderName);
      final backend = _table(shader, _openGlEsBackend);
      if (name == null || backend == null) {
        continue;
      }
      var vectors = 0;
      for (final struct in _tables(backend, _backendUniformStructs)) {
        vectors += (_scalar64(struct, _structSize) + 15) ~/ 16;
      }
      final source = _bytes(backend, _backendSource);
      final text = source == null ? '' : latin1.decode(source);
      result[name] = GpuShaderRequirements(
        stage: _scalar8(backend, _backendStage) == _vertexStage
            ? GpuShaderStage.vertex
            : GpuShaderStage.fragment,
        uniformVectors: vectors + looseUniformVectors(text),
        samplers: _tables(backend, _backendUniformTextures).length,
        extensions: requiredExtensions(text),
      );
    }
    return result;
  }

  bool _isBundle() {
    return _data.lengthInBytes >= 8 &&
        String.fromCharCodes([
              for (var i = 4; i < 8; i++) _data.getUint8(i),
            ]) ==
            'IPSB';
  }

  int _scalar8(int table, int index) {
    final field = _field(table, index);
    return field < 0 ? 0 : _data.getUint8(field);
  }

  Uint8List? _bytes(int table, int index) {
    final field = _field(table, index);
    if (field < 0) {
      return null;
    }
    final vector = _deref(field);
    return _data.buffer.asUint8List(
      _data.offsetInBytes + vector + 4,
      _u32(vector),
    );
  }

  int _u32(int position) => _data.getUint32(position, Endian.little);

  /// The absolute position of field [index] of the table at [table], or `-1`
  /// when the field is absent.
  int _field(int table, int index) {
    final vtable = table - _data.getInt32(table, Endian.little);
    final vtableSize = _data.getUint16(vtable, Endian.little);
    final entry = 4 + index * 2;
    if (entry >= vtableSize) {
      return -1;
    }
    final offset = _data.getUint16(vtable + entry, Endian.little);
    return offset == 0 ? -1 : table + offset;
  }

  int _deref(int position) => position + _u32(position);

  int? _table(int table, int index) {
    final field = _field(table, index);
    return field < 0 ? null : _deref(field);
  }

  List<int> _tables(int table, int index) {
    final field = _field(table, index);
    if (field < 0) {
      return const [];
    }
    final vector = _deref(field);
    final length = _u32(vector);
    return [
      for (var i = 0; i < length; i++) _deref(vector + 4 + i * 4),
    ];
  }

  String? _string(int table, int index) {
    final field = _field(table, index);
    if (field < 0) {
      return null;
    }
    final string = _deref(field);
    return utf8.decode(
      _data.buffer.asUint8List(
        _data.offsetInBytes + string + 4,
        _u32(string),
      ),
    );
  }

  int _scalar32(int table, int index) {
    final field = _field(table, index);
    return field < 0 ? 0 : _u32(field);
  }

  int _scalar64(int table, int index, {int fallback = 0}) {
    final field = _field(table, index);
    if (field < 0) {
      return fallback;
    }
    // Values are small, the high word is always zero.
    return _u32(field);
  }
}
