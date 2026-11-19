// Builds shader bundles from GLSL sources.
//
//   dart run flame_3d:build_shaders [--src <dir>] [--out <dir>]
//       [--with-web-gpu] [watch]
//
// Every `<name>.vert` + `<name>.frag` pair at the top of the source directory
// becomes `<name>.shaderbundle` (and `<name>.wgslbundle` with
// `--with-web-gpu`) in the output directory. Other files (lone stages,
// `#include` chunks, anything else) are not compiled. A shader can
// `#include "file.glsl"` from the source directory and
// `#include <pkg_name/file.glsl>` from the top-level `shaders/` directory of
// any Dart dependency, so a game's material can include the chunks of
// `flame_3d` (`#include <flame_3d/camera.glsl>`).
//
// Without `--src` and `--out` it builds the current package: `shaders/` into
// `assets/shaders/`, deleting the bundles of shaders that no longer exist
// first. With either option, the output directory may hold other files: only
// the bundles of the pairs found are written, nothing is deleted.
// `--src=<dir>` and `--out=<dir>` work too.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '_build_shaderbundle.dart' as shaderbundle;
import '_build_wgslbundle.dart' as wgslbundle;

void main(List<String> arguments) async {
  final withWebGpu = arguments.contains('--with-web-gpu');
  final root = Directory.current;
  final src = _option(arguments, 'src');
  final out = _option(arguments, 'out');
  final shaders = src != null
      ? Directory(src)
      : Directory.fromUri(root.uri.resolve('shaders'));
  final assets = out != null
      ? Directory(out)
      : Directory.fromUri(root.uri.resolve('assets/shaders'));
  final deleteStale = src == null && out == null;
  final packageShaderDirs = await _resolvePackageShaderDirs();

  Future<void> build() => _build(
    shaders,
    assets,
    packageShaderDirs,
    withWebGpu: withWebGpu,
    deleteStale: deleteStale,
  );
  await build();

  if (arguments.contains('watch')) {
    stdout.writeln('Running in watch mode');
    shaders.watch(recursive: true).listen((_) => build());
  }
}

/// The value of `--name <value>` or `--name=<value>` in [arguments].
String? _option(List<String> arguments, String name) {
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '--$name' && i + 1 < arguments.length) {
      return arguments[i + 1];
    }
    if (argument.startsWith('--$name=')) {
      return argument.substring(name.length + 3);
    }
  }
  return null;
}

Future<void> _build(
  Directory shaders,
  Directory assets,
  List<Directory> packageShaderDirs, {
  required bool withWebGpu,
  required bool deleteStale,
}) async {
  if (!shaders.existsSync()) {
    stderr.writeln('Missing shader directory ${shaders.path}');
    exitCode = 1;
    return;
  }
  assets.createSync(recursive: true);

  // The base names that have both a `.vert` and a `.frag` file. Nested files
  // (e.g. the `shaders/flame_3d/` `#include` chunks) are ignored.
  final files = {
    for (final file in shaders.listSync().whereType<File>())
      file.uri.pathSegments.last,
  };
  final names = {
    for (final file in files)
      if (file.endsWith('.vert') &&
          files.contains('${file.substring(0, file.length - 5)}.frag'))
        file.substring(0, file.length - 5),
  };

  await shaderbundle.build(
    names,
    shaders,
    assets,
    packageShaderDirs,
    deleteStale: deleteStale,
  );
  if (withWebGpu) {
    wgslbundle.build(
      names,
      shaders,
      assets,
      packageShaderDirs,
      deleteStale: deleteStale,
    );
  }
}

/// Returns every Dart dependency's top-level `shaders/` directory, so an
/// `#include <pkg_name/foo.glsl>` can resolve to
/// `<pkg-root>/shaders/pkg_name/foo.glsl`.
Future<List<Directory>> _resolvePackageShaderDirs() async {
  final configUri = await Isolate.packageConfig;
  if (configUri == null) {
    throw Exception(
      'Unable to locate package_config.json. Run `dart pub get` first.',
    );
  }

  final configFile = File.fromUri(configUri);
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>();
  final result = <Directory>[];
  for (final package in packages) {
    final name = package['name'] as String;
    if (name == 'flutter') {
      // `flutter` ships no shader chunks, they are included from the engine.
      continue;
    }

    final rootUriRaw = package['rootUri'] as String;
    final rootUri = configUri.resolve(
      rootUriRaw.endsWith('/') ? rootUriRaw : '$rootUriRaw/',
    );

    final shaderDir = Directory.fromUri(rootUri.resolve('shaders/'));
    if (shaderDir.existsSync()) {
      result.add(shaderDir);
    }
  }
  return result;
}
