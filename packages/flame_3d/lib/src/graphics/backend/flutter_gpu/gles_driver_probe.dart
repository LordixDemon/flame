import 'dart:ffi';
import 'dart:io';

/// What an OpenGL ES driver reports about itself: its strings, extensions and
/// the limits that decide whether a shader links.
class const GlesDriverInfo({
  required final String vendor,
  required final String renderer,
  required final String version,
  required final String shadingLanguageVersion,
  required final Set<String> extensions,
  required final int maxVertexUniformVectors,
  required final int maxFragmentUniformVectors,
  required final int maxVertexSamplers,
  required final int maxFragmentSamplers,
  required final int maxTextureSize,

  /// The extensions asked for that a GLSL ES 1.00 fragment shader can
  /// require: each was checked by compiling a shader that requires it.
  required final Set<String> shaderExtensions,
});

/// Asks the device's OpenGL ES driver for its strings, extensions and
/// limits, or returns `null` when it cannot (not on Android, no driver, an
/// error).
///
/// Flutter GPU does not expose them, so a private context is created through
/// EGL on the calling thread, queried and destroyed again. It shares the
/// display with Impeller's own contexts but nothing else: the display is not
/// terminated and whatever context was current on this thread is made
/// current again. It is the same driver, so its limits are the ones
/// Impeller's shaders are linked against.
///
/// Each of [shaderExtensions] is checked by compiling a GLSL ES 1.00 fragment
/// shader that requires it (`#extension NAME : require`), as the shaders of
/// OpenGL ES bundles do: drivers accept some extensions they do not list (in
/// an OpenGL ES 3 context, `GL_OES_standard_derivatives`), and the reverse.
GlesDriverInfo? probeGlesDriver({Set<String> shaderExtensions = const {}}) {
  if (!Platform.isAndroid) {
    return null;
  }
  try {
    return _GlesProbe(shaderExtensions).run();
    // A device without a usable driver is reported as unknown limits.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return null;
  }
}

// EGL and OpenGL ES constants.
const int _eglNone = 0x3038;
const int _eglRenderableType = 0x3040;
const int _eglOpenGlEs2Bit = 0x0004;
const int _eglSurfaceType = 0x3033;
const int _eglPbufferBit = 0x0001;
const int _eglWidth = 0x3057;
const int _eglHeight = 0x3056;
const int _eglContextClientVersion = 0x3098;
const int _eglDraw = 0x3059;
const int _eglRead = 0x305A;
const int _glVendor = 0x1F00;
const int _glRenderer = 0x1F01;
const int _glVersion = 0x1F02;
const int _glExtensions = 0x1F03;
const int _glShadingLanguageVersion = 0x8B8C;
const int _glMaxVertexUniformVectors = 0x8DFB;
const int _glMaxFragmentUniformVectors = 0x8DFD;
const int _glMaxTextureImageUnits = 0x8872;
const int _glMaxVertexTextureImageUnits = 0x8B4C;
const int _glMaxTextureSize = 0x0D33;
const int _glFragmentShader = 0x8B30;
const int _glCompileStatus = 0x8B81;

typedef _Ptr = Pointer<Void>;

class _GlesProbe(final Set<String> _shaderExtensions) {
  final DynamicLibrary _egl = DynamicLibrary.open('libEGL.so');
  final DynamicLibrary _gles = DynamicLibrary.open('libGLESv2.so');
  final DynamicLibrary _libc = DynamicLibrary.open('libc.so');

  late final _malloc = _libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >(
        'malloc',
      );
  late final _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >(
        'free',
      );

  late final _getDisplay = _egl
      .lookupFunction<_Ptr Function(_Ptr), _Ptr Function(_Ptr)>(
        'eglGetDisplay',
      );
  late final _initialize = _egl
      .lookupFunction<
        Uint32 Function(_Ptr, Pointer<Int32>, Pointer<Int32>),
        int Function(_Ptr, Pointer<Int32>, Pointer<Int32>)
      >('eglInitialize');
  late final _chooseConfig = _egl
      .lookupFunction<
        Uint32 Function(
          _Ptr,
          Pointer<Int32>,
          Pointer<_Ptr>,
          Int32,
          Pointer<Int32>,
        ),
        int Function(_Ptr, Pointer<Int32>, Pointer<_Ptr>, int, Pointer<Int32>)
      >('eglChooseConfig');
  late final _createPbufferSurface = _egl
      .lookupFunction<
        _Ptr Function(_Ptr, _Ptr, Pointer<Int32>),
        _Ptr Function(_Ptr, _Ptr, Pointer<Int32>)
      >('eglCreatePbufferSurface');
  late final _createContext = _egl
      .lookupFunction<
        _Ptr Function(_Ptr, _Ptr, _Ptr, Pointer<Int32>),
        _Ptr Function(_Ptr, _Ptr, _Ptr, Pointer<Int32>)
      >('eglCreateContext');
  late final _makeCurrent = _egl
      .lookupFunction<
        Uint32 Function(_Ptr, _Ptr, _Ptr, _Ptr),
        int Function(_Ptr, _Ptr, _Ptr, _Ptr)
      >('eglMakeCurrent');
  late final _getCurrentContext = _egl
      .lookupFunction<_Ptr Function(), _Ptr Function()>('eglGetCurrentContext');
  late final _getCurrentDisplay = _egl
      .lookupFunction<_Ptr Function(), _Ptr Function()>('eglGetCurrentDisplay');
  late final _getCurrentSurface = _egl
      .lookupFunction<_Ptr Function(Int32), _Ptr Function(int)>(
        'eglGetCurrentSurface',
      );
  late final _destroyContext = _egl
      .lookupFunction<Uint32 Function(_Ptr, _Ptr), int Function(_Ptr, _Ptr)>(
        'eglDestroyContext',
      );
  late final _destroySurface = _egl
      .lookupFunction<Uint32 Function(_Ptr, _Ptr), int Function(_Ptr, _Ptr)>(
        'eglDestroySurface',
      );
  late final _getString = _gles
      .lookupFunction<
        Pointer<Uint8> Function(Uint32),
        Pointer<Uint8> Function(int)
      >(
        'glGetString',
      );
  late final _createShader = _gles
      .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'glCreateShader',
      );
  late final _shaderSource = _gles
      .lookupFunction<
        Void Function(Uint32, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>),
        void Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)
      >('glShaderSource');
  late final _compileShader = _gles
      .lookupFunction<Void Function(Uint32), void Function(int)>(
        'glCompileShader',
      );
  late final _getShaderiv = _gles
      .lookupFunction<
        Void Function(Uint32, Uint32, Pointer<Int32>),
        void Function(int, int, Pointer<Int32>)
      >('glGetShaderiv');
  late final _deleteShader = _gles
      .lookupFunction<Void Function(Uint32), void Function(int)>(
        'glDeleteShader',
      );
  late final _getIntegerv = _gles
      .lookupFunction<
        Void Function(Uint32, Pointer<Int32>),
        void Function(int, Pointer<Int32>)
      >('glGetIntegerv');

  GlesDriverInfo? run() {
    final memory = _malloc(256);
    if (memory.address == 0) {
      return null;
    }
    final ints = memory.cast<Int32>();
    final pointers = Pointer<_Ptr>.fromAddress(memory.address + 128);
    try {
      return _query(ints, pointers);
    } finally {
      _free(memory);
    }
  }

  GlesDriverInfo? _query(Pointer<Int32> ints, Pointer<_Ptr> pointers) {
    final display = _getDisplay(nullptr);
    if (display.address == 0 || _initialize(display, ints, ints + 1) == 0) {
      return null;
    }
    _fill(ints, const [
      _eglRenderableType,
      _eglOpenGlEs2Bit,
      _eglSurfaceType,
      _eglPbufferBit,
      _eglNone,
    ]);
    final count = ints + 16;
    if (_chooseConfig(display, ints, pointers, 1, count) == 0 ||
        count.value < 1) {
      return null;
    }
    final config = pointers.value;
    _fill(ints, const [_eglWidth, 1, _eglHeight, 1, _eglNone]);
    final surface = _createPbufferSurface(display, config, ints);
    if (surface.address == 0) {
      return null;
    }
    // Version 2, as asked by most renderers: the driver may give a later
    // version compatible with it; the limits do not depend on it.
    _fill(ints, const [_eglContextClientVersion, 2, _eglNone]);
    final context = _createContext(display, config, nullptr, ints);
    if (context.address == 0) {
      _destroySurface(display, surface);
      return null;
    }
    final previousDisplay = _getCurrentDisplay();
    final previousContext = _getCurrentContext();
    final previousDraw = _getCurrentSurface(_eglDraw);
    final previousRead = _getCurrentSurface(_eglRead);
    try {
      if (_makeCurrent(display, surface, surface, context) == 0) {
        return null;
      }
      int integer(int name) {
        ints.value = 0;
        _getIntegerv(name, ints);
        return ints.value;
      }

      final extensions = _string(_glExtensions);
      return GlesDriverInfo(
        vendor: _string(_glVendor),
        renderer: _string(_glRenderer),
        version: _string(_glVersion),
        shadingLanguageVersion: _string(_glShadingLanguageVersion),
        extensions: {
          for (final extension in extensions.split(' '))
            if (extension.isNotEmpty) extension,
        },
        maxVertexUniformVectors: integer(_glMaxVertexUniformVectors),
        maxFragmentUniformVectors: integer(_glMaxFragmentUniformVectors),
        maxVertexSamplers: integer(_glMaxVertexTextureImageUnits),
        maxFragmentSamplers: integer(_glMaxTextureImageUnits),
        maxTextureSize: integer(_glMaxTextureSize),
        shaderExtensions: {
          for (final extension in _shaderExtensions)
            if (_compiles(extension, ints)) extension,
        },
      );
    } finally {
      if (previousContext.address != 0 && previousDisplay.address != 0) {
        _makeCurrent(
          previousDisplay,
          previousDraw,
          previousRead,
          previousContext,
        );
      } else {
        _makeCurrent(display, nullptr, nullptr, nullptr);
      }
      _destroyContext(display, context);
      _destroySurface(display, surface);
    }
  }

  /// Whether a GLSL ES 1.00 fragment shader that requires [extension]
  /// compiles, in the current context.
  bool _compiles(String extension, Pointer<Int32> status) {
    if (!RegExp(r'^\w+$').hasMatch(extension)) {
      return false;
    }
    final source =
        '#version 100\n'
        '#extension $extension : require\n'
        'precision mediump float;\n'
        'void main() { gl_FragColor = vec4(0.0); }\n';
    final codes = source.codeUnits;
    final memory = _malloc(codes.length + 1 + 16);
    if (memory.address == 0) {
      return false;
    }
    try {
      final text = memory.cast<Uint8>();
      for (var i = 0; i < codes.length; i++) {
        text[i] = codes[i];
      }
      text[codes.length] = 0;
      final strings = Pointer<Pointer<Uint8>>.fromAddress(
        (memory.address + codes.length + 1 + 7) & ~7,
      )..value = text;
      final shader = _createShader(_glFragmentShader);
      if (shader == 0) {
        return false;
      }
      try {
        _shaderSource(shader, 1, strings, nullptr);
        _compileShader(shader);
        status.value = 0;
        _getShaderiv(shader, _glCompileStatus, status);
        return status.value != 0;
      } finally {
        _deleteShader(shader);
      }
    } finally {
      _free(memory);
    }
  }

  static void _fill(Pointer<Int32> ints, List<int> values) {
    for (var i = 0; i < values.length; i++) {
      ints[i] = values[i];
    }
  }

  String _string(int name) {
    final pointer = _getString(name);
    if (pointer.address == 0) {
      return '';
    }
    final codes = <int>[];
    for (var i = 0; ; i++) {
      final code = pointer[i];
      if (code == 0) {
        break;
      }
      codes.add(code);
    }
    return String.fromCharCodes(codes);
  }
}
