import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Measures the frames of `benchmark/frame_scene.dart` in AOT code: the time
/// of each phase (update, render, hover, tap hit-test), the objects that each
/// phase allocates, and where the time goes.
///
/// It runs `benchmark/frame_scene_app.dart` in a profile build with
/// `flutter run --machine`, connects to its VM service, and drives the scene
/// through the service extension `ext.flame.frameScene`.
///
/// The objects are counted by tracing the allocations of every class of the
/// app, which the VM records one by one, so the counts are exact. Each object
/// is attributed to the phase whose function is on its stack
/// (`FrameSceneGame.step`, `renderFrame`, `renderEmissivePass`, `hover` or
/// `hitTest`), so what the
/// VM service allocates itself is not counted. The time is measured by the
/// app, without tracing.
///
///     dart run benchmark/tool/measure_frame_scene.dart [options]
///
/// Options:
///
///     --app-dir=examples   A directory with a Flutter app that depends on
///                          this package and has a runner for the device
///                          (`flutter create --platforms=macos .` adds one).
///     --device=macos       The device to run on. It needs to be a desktop one.
///     --entry=path         The app to run instead of `frame_scene_app.dart`
///                          next to this tool, such as a copy of it in a
///                          checkout of another branch (whose package the app
///                          directory then depends on).
///     --repetitions=5      The timings of each phase.
///     --frames=2000        The frames of each timing.
///     --trace-frames=240   The frames that the allocations are counted for.
///     --sites=12           The allocation sites shown for each phase.
///     --cpu=0              The frames of a CPU profile to show (0: none).
///     --cpu-only=false     Only show the CPU profile.
///     --csv=path           Also write the results to a CSV file.
///
/// The first run needs a profile build, which takes minutes. To compare a
/// change, run it on both branches.
Future<void> main(List<String> arguments) async {
  final options = _Options(arguments);
  final app = await _App.start(options);
  final csv = <String>['phase,microseconds_per_frame,objects_per_frame'];
  try {
    await app.connect();
    // Builds the scene and warms up the code.
    await app.run('frame', 1200);
    if (options.cpuOnly) {
      await app.profile(max(options.cpuFrames, 1));
      return;
    }

    stdout
      ..writeln()
      ..writeln(
        'Frame scene (${app.components} components) in ${app.description}.\n'
        'time: median (fastest-slowest) of ${options.repetitions} timings of '
        '${options.frames} frames, without tracing. objects: exact, from '
        'tracing the allocations of every class in ${options.traceFrames} '
        'frames.\n',
      );

    final timings = <String, (double, double, double)>{};
    for (final phase in _phases) {
      final micros = <double>[];
      for (var i = 0; i < options.repetitions; i++) {
        final result = await app.run(phase, options.frames);
        micros.add((result['micros'] as int) / options.frames);
      }
      micros.sort();
      timings[phase] = (micros[micros.length ~/ 2], micros.first, micros.last);
    }

    final counted = await app.countAllocations(options.traceFrames);
    stdout.writeln(
      '${'phase'.padRight(10)}${'us/frame'.padRight(26)}objects/frame',
    );
    for (final phase in _phases) {
      final (median, fastest, slowest) = timings[phase]!;
      final objects = phase == 'frame'
          ? counted.byPhase.values.fold<int>(0, (s, m) => s + _sum(m))
          : _sum(counted.byPhase[phase] ?? const {});
      final perFrame = objects / options.traceFrames;
      final range =
          '(${fastest.toStringAsFixed(1)}-${slowest.toStringAsFixed(1)})';
      final time = '${median.toStringAsFixed(1)} $range';
      stdout.writeln(
        '${phase.padRight(10)}${time.padRight(26)}'
        '${perFrame.toStringAsFixed(1)}',
      );
      csv.add(
        '$phase,${median.toStringAsFixed(2)},${perFrame.toStringAsFixed(2)}',
      );
    }
    if (counted.truncated) {
      stdout.writeln('(TRUNCATED: some allocations were not recorded)');
    }

    for (final phase in _phases.where((p) => p != 'frame')) {
      final classes = counted.byPhase[phase] ?? const <String, int>{};
      if (classes.isEmpty) {
        continue;
      }
      stdout
        ..writeln()
        ..writeln('$phase, objects per frame by class:')
        ..writeln('  ${_top(classes, options.traceFrames, count: 12)}')
        ..writeln('$phase, objects per frame by allocation site:');
      final sites = counted.sitesByPhase[phase]!.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final site in sites.take(options.sites)) {
        final perFrame = site.value / options.traceFrames;
        stdout.writeln(
          '  ${perFrame.toStringAsFixed(2).padLeft(7)}  ${site.key}',
        );
      }
    }

    if (options.cpuFrames > 0) {
      await app.profile(options.cpuFrames);
    }
    final path = options.csvPath;
    if (path != null) {
      await File(path).writeAsString('${csv.join('\n')}\n');
      stdout.writeln('Written to $path');
    }
  } on Object catch (error, stackTrace) {
    stdout
      ..writeln('FAILED: $error\n$stackTrace')
      ..writeln('Last output of flutter:')
      ..writeln(app.log.reversed.take(25).toList().reversed.join('\n'));
    exitCode = 1;
  } finally {
    await app.stop();
  }
}

const _phases = ['update', 'render', 'emissive', 'hover', 'hitTest', 'frame'];

/// The function on the stack of an allocation that tells its phase.
const _phaseRoots = {
  'FrameSceneGame.step': 'update',
  'FrameSceneGame.renderFrame': 'render',
  'FrameSceneGame.renderEmissivePass': 'emissive',
  'FrameSceneGame.hover': 'hover',
  'FrameSceneGame.hitTest': 'hitTest',
};

int _sum(Map<String, int> counts) =>
    counts.values.fold(0, (sum, count) => sum + count);

/// The classes with the most objects, as `name objects/frame`.
String _top(Map<String, int> counts, int frames, {int count = 6}) {
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries
      .take(count)
      .map((e) => '${e.key} ${(e.value / frames).toStringAsFixed(1)}')
      .join(', ');
}

class _Options(List<String> arguments) {
  this {
    for (final argument in arguments) {
      final match = RegExp(r'^--([\w-]+)=(.*)$').firstMatch(argument);
      if (match == null) {
        throw ArgumentError('Unknown argument: $argument');
      }
      final value = match.group(2)!;
      switch (match.group(1)) {
        case 'app-dir':
          appDir = value;
        case 'device':
          device = value;
        case 'entry':
          entry = value;
        case 'repetitions':
          repetitions = int.parse(value);
        case 'frames':
          frames = int.parse(value);
        case 'trace-frames':
          traceFrames = int.parse(value);
        case 'sites':
          sites = int.parse(value);
        case 'cpu':
          cpuFrames = int.parse(value);
        case 'cpu-only':
          cpuOnly = value == 'true';
        case 'csv':
          csvPath = value;
        default:
          throw ArgumentError('Unknown option: $argument');
      }
    }
  }

  String? appDir;
  String device = 'macos';
  String? entry;
  int repetitions = 5;
  int frames = 2000;
  int traceFrames = 240;
  int sites = 12;
  int cpuFrames = 0;
  bool cpuOnly = false;
  String? csvPath;
}

/// The objects allocated in the traced frames, by phase and class, and by
/// phase and allocation site, and whether the VM may have dropped samples.
typedef _Counted = ({
  Map<String, Map<String, int>> byPhase,
  Map<String, Map<String, int>> sitesByPhase,
  bool truncated,
});

/// The app run by `flutter run --machine`, and its VM service.
class _App._(final Process _process) {
  /// The samples that one chunk may have without the VM dropping some, which
  /// it does when its buffer of samples is full.
  static const _sampleBufferLimit = 40000;

  final log = <String>[];
  final _wsUri = Completer<String>();
  final _started = Completer<void>();
  String? _appId;
  VmService? _service;
  String? _isolateId;
  String description = '';
  int components = 0;

  static Future<_App> start(_Options options) async {
    final entry = options.entry == null
        ? Platform.script.resolve('../frame_scene_app.dart')
        : File(options.entry!).absolute.uri;
    final appDir = options.appDir == null
        ? Platform.script.resolve('../../../../examples').toFilePath()
        : Directory(options.appDir!).absolute.path;
    stdout.writeln('Starting the app (a profile build can take minutes)...');
    final process = await Process.start(
      'flutter',
      [
        'run',
        '-d',
        options.device,
        '--profile',
        '--machine',
        '-t',
        entry.toFilePath(),
      ],
      workingDirectory: appDir,
    );
    final app = _App._(process);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(app._onLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(app.log.add);
    return app;
  }

  void _onLine(String line) {
    log.add(line);
    if (!line.startsWith('[')) {
      return;
    }
    try {
      for (final message in jsonDecode(line) as List<dynamic>) {
        final event = (message as Map<String, dynamic>)['event'];
        final params = message['params'] as Map<String, dynamic>?;
        if (event == 'app.debugPort' && !_wsUri.isCompleted) {
          _appId = params!['appId'] as String;
          _wsUri.complete(params['wsUri'] as String);
        } else if (event == 'app.started' && !_started.isCompleted) {
          _started.complete();
        }
      }
    } on Object {
      // Not a message that matters.
    }
  }

  Future<void> connect() async {
    final uri = await _wsUri.future.timeout(const Duration(minutes: 15));
    await _started.future.timeout(const Duration(minutes: 5));
    final service = _service = await vmServiceConnectUri(uri);
    final vm = await service.getVM();
    description = '${vm.version?.split(' ').first} ${vm.targetCPU}';
    for (var attempt = 0; attempt < 30 && _isolateId == null; attempt++) {
      for (final ref in (await service.getVM()).isolates ?? <IsolateRef>[]) {
        final isolate = await service.getIsolate(ref.id!);
        if (isolate.extensionRPCs?.contains('ext.flame.frameScene') ?? false) {
          _isolateId = ref.id;
        }
      }
      if (_isolateId == null) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (_isolateId == null) {
      throw StateError('No isolate has the extension ext.flame.frameScene');
    }
    final check = await run('none', 0);
    if (check['profileMode'] != true) {
      throw StateError('The app is not a profile build: $check');
    }
    components = check['components'] as int;
    description = 'a profile build (AOT), $description';
  }

  Future<Map<String, dynamic>> run(String phase, int frames) async {
    final response = await _service!.callServiceExtension(
      'ext.flame.frameScene',
      isolateId: _isolateId,
      args: {'phase': phase, 'frames': '$frames'},
    );
    return response.json!;
  }

  /// The objects allocated in [frames] frames, by phase, in chunks of frames
  /// as many as the VM can record at a time.
  Future<_Counted> countAllocations(int frames, {int chunk = 16}) async {
    final service = _service!;
    final isolateId = _isolateId!;
    final classes = await service.getClassList(isolateId);
    final names = <int, String>{};
    final ids = <String>[];
    for (final ref in classes.classes ?? <ClassRef>[]) {
      final numeric = int.tryParse(ref.id!.split('/').last);
      if (numeric != null && ref.name != null) {
        names[numeric] = ref.name!;
        ids.add(ref.id!);
      }
    }
    final byPhase = <String, Map<String, int>>{};
    final sitesByPhase = <String, Map<String, int>>{};
    var truncated = false;
    await Future.wait([
      for (final id in ids)
        service.setTraceClassAllocation(isolateId, id, true),
    ]);
    try {
      var remaining = frames;
      var size = chunk;
      while (remaining > 0) {
        final n = min(size, remaining);
        final origin = (await service.getVMTimelineMicros()).timestamp!;
        await run('frame', n);
        final samples = await service.getAllocationTraces(
          isolateId,
          timeOriginMicros: origin,
          timeExtentMicros: 10 * 60 * 1000000,
        );
        final list = samples.samples ?? <CpuSample>[];
        if (list.length >= _sampleBufferLimit) {
          if (n > 1) {
            size = n ~/ 2;
            continue;
          }
          truncated = true;
        }
        remaining -= n;
        final functions = samples.functions ?? <ProfileFunction>[];
        final functionNames = [for (final f in functions) _name(f)];
        for (final sample in list) {
          final stack = sample.stack ?? const <int>[];
          String? phase;
          for (final index in stack) {
            phase = _phaseRoots[functionNames[index]];
            if (phase != null) {
              break;
            }
          }
          if (phase == null) {
            continue;
          }
          final name = names[sample.classId] ?? '?';
          final classes = byPhase.putIfAbsent(phase, () => {});
          classes[name] = (classes[name] ?? 0) + 1;
          final site = '$name  <  ${_site(stack, functionNames)}';
          final sites = sitesByPhase.putIfAbsent(phase, () => {});
          sites[site] = (sites[site] ?? 0) + 1;
        }
      }
    } finally {
      await Future.wait([
        for (final id in ids)
          service.setTraceClassAllocation(isolateId, id, false),
      ]);
    }
    return (
      byPhase: byPhase,
      sitesByPhase: sitesByPhase,
      truncated: truncated,
    );
  }

  /// The innermost functions of [stack] that are not part of the core
  /// libraries, which is where an allocation comes from.
  static String _site(List<int> stack, List<String> names) {
    final parts = <String>[];
    for (final index in stack) {
      final name = names[index];
      if (parts.isEmpty && _isCore(name)) {
        continue;
      }
      parts.add(name);
      if (parts.length == 3) {
        break;
      }
    }
    if (parts.isEmpty && stack.isNotEmpty) {
      parts.add(names[stack.first]);
    }
    return parts.join(' < ');
  }

  static bool _isCore(String name) =>
      name.startsWith('_') ||
      name.startsWith('[') ||
      name.startsWith('List.') ||
      name.startsWith('Iterable.') ||
      name.startsWith('Object.') ||
      name.startsWith('Map.') ||
      name.startsWith('Set.') ||
      name.startsWith('Vector2.') ||
      name.startsWith('Float64List.') ||
      name.startsWith('Float32List.') ||
      name.startsWith('LinkedHashMap.') ||
      name.startsWith('HashMap.') ||
      name.startsWith('HashSet.');

  static String _name(ProfileFunction function) {
    final f = function.function;
    if (f is FuncRef) {
      final owner = f.owner;
      final ownerName = owner is ClassRef
          ? '${owner.name}.'
          : owner is FuncRef
          ? '${owner.name}.'
          : '';
      return '$ownerName${f.name}';
    }
    return f is NativeFunction ? f.name ?? '?' : '$f';
  }

  /// Prints the functions where [frames] frames spend their time, from a CPU
  /// profile, by exclusive and by inclusive samples.
  Future<void> profile(int frames) async {
    final service = _service!;
    final isolateId = _isolateId!;
    // A sample every 100 microseconds instead of every millisecond.
    await service.setFlag('profile_period', '100');
    await service.clearCpuSamples(isolateId);
    final origin = (await service.getVMTimelineMicros()).timestamp!;
    await run('frame', frames);
    final extent = (await service.getVMTimelineMicros()).timestamp! - origin;
    final samples = await service.getCpuSamples(isolateId, origin, extent);
    final functions = samples.functions ?? <ProfileFunction>[];
    final names = [for (final f in functions) _name(f)];
    final exclusive = <String, Map<String, int>>{};
    final inclusive = <String, Map<String, int>>{};
    final byPhase = <String, int>{};
    var total = 0;
    for (final sample in samples.samples ?? <CpuSample>[]) {
      final stack = sample.stack ?? const <int>[];
      String? phase;
      var depth = 0;
      for (; depth < stack.length; depth++) {
        phase = _phaseRoots[names[stack[depth]]];
        if (phase != null) {
          break;
        }
      }
      if (phase == null) {
        continue;
      }
      total++;
      byPhase[phase] = (byPhase[phase] ?? 0) + 1;
      final top = names[stack.first];
      final phaseExclusive = exclusive.putIfAbsent(phase, () => {});
      phaseExclusive[top] = (phaseExclusive[top] ?? 0) + 1;
      final phaseInclusive = inclusive.putIfAbsent(phase, () => {});
      // Only the frames below the root of the phase.
      for (final name in {
        for (var i = 0; i < depth; i++) names[stack[i]],
      }) {
        phaseInclusive[name] = (phaseInclusive[name] ?? 0) + 1;
      }
    }
    String pct(int n, int of) =>
        '${(100 * n / max(1, of)).toStringAsFixed(1)}%';
    stdout
      ..writeln()
      ..writeln('CPU profile of $frames frames, $total samples in the phases:')
      ..writeln(
        '  ${[
          for (final e in byPhase.entries) '${e.key} ${pct(e.value, total)}',
        ].join(', ')}',
      );
    for (final phase in byPhase.keys) {
      final count = byPhase[phase]!;
      for (final (title, counts, shown) in [
        ('exclusive', exclusive[phase]!, 30),
        ('inclusive', inclusive[phase]!, 60),
      ]) {
        final sorted = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        stdout.writeln(
          '$phase ($count samples), top functions, $title, '
          'percent of the phase:',
        );
        for (final entry in sorted.take(shown)) {
          stdout.writeln(
            '  ${pct(entry.value, count).padLeft(6)}  ${entry.key}',
          );
        }
      }
    }
  }

  Future<void> stop() async {
    await _service?.dispose();
    if (_appId != null) {
      _process.stdin.writeln(
        jsonEncode([
          {
            'id': 1,
            'method': 'app.stop',
            'params': {'appId': _appId},
          },
        ]),
      );
    }
    await _process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
  }
}
