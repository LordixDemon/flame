import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flame/src/game/frame_budget_scheduler.dart';
import 'package:flutter/services.dart';

/// Cooperative cancellation token for [AsyncAssetStreamer] background loads.
class StreamCancellationToken() {
  bool _isCancelled = false;

  /// Whether [cancel] has been requested.
  bool get isCancelled => _isCancelled;

  /// Signals in-flight streaming operations to abort before GPU upload or
  /// finalization.
  void cancel() {
    _isCancelled = true;
  }
}

/// Exception thrown when a [StreamCancellationToken] aborts an in-flight load.
class const AssetStreamCancelledException([final String? assetKey])
    implements Exception {
  @override
  String toString() => 'AssetStreamCancelledException(${assetKey ?? ""})';
}

/// Hitch-free background asset decoder & parser executing heavy CPU parsing
/// (large JSON maps, `.dmesh` binary buffers, tile grids) on worker isolates
/// via [Isolate.run] and finalizing main-thread GPU/scene commits inside a
/// [FrameBudgetScheduler].
class AsyncAssetStreamer({
  AssetBundle? bundle,
  this.scheduler,
}) {
  /// Optional [AssetBundle] used by [loadAndParseJson].
  final AssetBundle bundle = bundle ?? rootBundle;

  /// Optional frame-budgeted main-thread scheduler for finalization steps.
  final FrameBudgetScheduler? scheduler;

  int _completedStreams = 0;

  /// Total streaming operations finalized without cancellation.
  int get completedStreams => _completedStreams;

  /// Parses [jsonText] on a background worker isolate (`Isolate.run` when
  /// length >= [isolateThresholdChars]) and optionally commits the parsed value
  /// within [scheduler]'s frame budget.
  ///
  /// Only [jsonText] is sent to the worker isolate. [mapper] runs on the
  /// calling isolate and can use any main-thread state.
  Future<R> parseJsonInBackground<R>(
    String jsonText,
    R Function(Object? decodedJson) mapper, {
    int isolateThresholdChars = 2048,
    int priority = 0,
    StreamCancellationToken? cancelToken,
  }) async {
    _checkCancelled(cancelToken);
    final Object? decoded;
    if (jsonText.length >= isolateThresholdChars) {
      decoded = await _decodeJsonInIsolate(jsonText);
    } else {
      decoded = jsonDecode(jsonText);
    }
    _checkCancelled(cancelToken);

    final sched = scheduler;
    final R result;
    if (sched != null) {
      result = await sched.schedule<R>(
        () {
          _checkCancelled(cancelToken);
          return mapper(decoded);
        },
        priority: priority,
      );
    } else {
      result = mapper(decoded);
    }
    _completedStreams++;
    return result;
  }

  /// Transforms a raw binary payload on a background isolate (sending a
  /// transferable copy) and commits the resulting main-thread object via
  /// [finalizeOnMainThread].
  ///
  /// Only [isolateWorker] and the bytes are sent to the worker isolate, so
  /// [isolateWorker] must be a top-level function, a `static` method, or a
  /// closure that captures nothing unsendable. [finalizeOnMainThread] never
  /// leaves the calling isolate and can use any main-thread state.
  Future<R> transformBytesInBackground<T, R>(
    Uint8List rawBytes,
    T Function(Uint8List bytes) isolateWorker,
    R Function(T workerOutput) finalizeOnMainThread, {
    int priority = 0,
    StreamCancellationToken? cancelToken,
  }) async {
    _checkCancelled(cancelToken);
    final workerResult = await _transformInIsolate<T>(isolateWorker, rawBytes);
    _checkCancelled(cancelToken);

    final sched = scheduler;
    final R result;
    if (sched != null) {
      result = await sched.schedule<R>(
        () {
          _checkCancelled(cancelToken);
          return finalizeOnMainThread(workerResult);
        },
        priority: priority,
      );
    } else {
      result = finalizeOnMainThread(workerResult);
    }
    _completedStreams++;
    return result;
  }

  /// Loads [assetPath] from [bundle], decodes JSON on a background isolate, and
  /// maps it inside [scheduler]'s frame budget.
  Future<R> loadAndParseJson<R>(
    String assetPath,
    R Function(Object? decodedJson) mapper, {
    int priority = 0,
    StreamCancellationToken? cancelToken,
  }) async {
    _checkCancelled(cancelToken, assetPath);
    final rawText = await bundle.loadString(assetPath);
    return await parseJsonInBackground<R>(
      rawText,
      mapper,
      priority: priority,
      cancelToken: cancelToken,
    );
  }

  // The closures that run on the worker isolate are created in these static
  // helpers on purpose: a closure is sent together with every variable of the
  // scope it was created in, so creating them inside the methods above would
  // also send the caller's main-thread callbacks and whatever they capture.

  static Future<Object?> _decodeJsonInIsolate(String jsonText) {
    return Isolate.run<Object?>(() => jsonDecode(jsonText));
  }

  static Future<T> _transformInIsolate<T>(
    T Function(Uint8List bytes) isolateWorker,
    Uint8List rawBytes,
  ) {
    // Copied once here and handed over to the worker without another copy.
    final transferable = TransferableTypedData.fromList(<TypedData>[rawBytes]);
    return Isolate.run<T>(
      () => isolateWorker(transferable.materialize().asUint8List()),
    );
  }

  static void _checkCancelled(
    StreamCancellationToken? token, [
    String? key,
  ]) {
    if (token != null && token.isCancelled) {
      throw AssetStreamCancelledException(key);
    }
  }
}
