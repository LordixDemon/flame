import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Shader compilation', () {
    test('shader bundles are up-to-date with sources', () async {
      final packageRoot = Directory.current;
      final assetsDir = Directory.fromUri(
        packageRoot.uri.resolve('assets/shaders'),
      );

      final bundles = assetsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.shaderbundle'))
          .toList();

      // Recompile the shaders into a temporary directory: the shipped bundles
      // are never rewritten, so GPU tests loading them can run at the same
      // time.
      final outDir = Directory.systemTemp.createTempSync('flame3d_bundles');
      addTearDown(() => outDir.deleteSync(recursive: true));
      final result = await Process.run(
        'dart',
        ['run', 'bin/build_shaders.dart', '--out-dir=${outDir.path}'],
        workingDirectory: packageRoot.path,
      );

      expect(
        result.exitCode,
        equals(0),
        reason: 'Shader compilation failed:\n${result.stderr}',
      );

      final fresh = {
        for (final file in outDir.listSync().whereType<File>())
          file.uri.pathSegments.last: file,
      };
      expect(
        fresh.keys.toSet(),
        {for (final bundle in bundles) bundle.uri.pathSegments.last},
        reason:
            'The shipped bundles do not match the shader sources. '
            'Run: dart run bin/build_shaders.dart',
      );
      for (final bundle in bundles) {
        final name = bundle.uri.pathSegments.last;
        expect(
          fresh[name]!.readAsBytesSync(),
          equals(bundle.readAsBytesSync()),
          reason:
              'Shader bundle "$name" is out of sync with its sources. '
              'Run: dart run bin/build_shaders.dart',
        );
      }
    });
  });
}
