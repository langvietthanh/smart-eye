import 'dart:async';
import 'dart:isolate';

/// State and native resources belong to the worker for its entire lifetime.
abstract class IsolateProcessor<Request, Response> {
  FutureOr<void> initialize();
  FutureOr<Response> process(Request request);
  FutureOr<void> dispose();
}

/// A persistent worker with one request in flight and graceful shutdown.
/// Dropping frames at the caller avoids a queue of increasingly stale images.
class ProcessingWorker<Request, Response> {
  ProcessingWorker._();

  final _ready = Completer<SendPort>();
  final _done = Completer<void>();
  final _replies = ReceivePort();
  Completer<Response>? _pending;
  SendPort? _requests;
  bool _closing = false;

  static Future<ProcessingWorker<Q, R>> start<Q, R>(
    IsolateProcessor<Q, R> processor,
  ) async {
    final worker = ProcessingWorker<Q, R>._();
    worker._replies.listen(worker._receive);
    // Attach an error handler before spawning: initialization can fail before
    // Isolate.spawn's future returns on the UI isolate.
    final ready = worker._ready.future;
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    try {
      await Isolate.spawn(
        _serve<Q, R>,
        (processor, worker._replies.sendPort),
        debugName: 'smart-eye-processing',
        onError: worker._replies.sendPort,
        onExit: worker._replies.sendPort,
      );
      worker._requests = await ready;
      return worker;
    } catch (_) {
      worker._closing = true;
      worker._replies.close();
      rethrow;
    }
  }

  Future<Response> run(Request request) {
    if (_closing || _done.isCompleted) {
      return Future.error(StateError('Processing worker is closed'));
    }
    if (_pending != null) {
      return Future.error(StateError('Processing worker is busy'));
    }
    final result = Completer<Response>();
    _pending = result;
    try {
      _requests!.send(request);
    } catch (error, stack) {
      _pending = null;
      result.completeError(error, stack);
    }
    return result.future;
  }

  /// The stop message runs after the active frame, so native tensors cannot be
  /// freed while inference is reading them. Repeated close calls share a future.
  Future<void> close() {
    if (!_closing) {
      _closing = true;
      _requests?.send(null);
    }
    return _done.future;
  }

  void _receive(Object? message) {
    if (message is SendPort) {
      _ready.complete(message);
    } else if (message is _WorkerResult<Response>) {
      final pending = _pending;
      _pending = null;
      pending?.complete(message.value);
    } else if (message is _WorkerFailure) {
      _fail(RemoteError(message.error, message.stack));
    } else if (message is List) {
      _fail(RemoteError('${message[0]}', '${message[1]}'));
    } else if (message == null) {
      _closing = true;
      _fail(StateError('Processing worker exited'));
      _replies.close();
      if (!_done.isCompleted) _done.complete();
    }
  }

  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    final pending = _pending;
    _pending = null;
    pending?.completeError(error);
  }
}

Future<void> _serve<Q, R>((IsolateProcessor<Q, R>, SendPort) arguments) async {
  final (processor, replies) = arguments;
  final requests = ReceivePort();
  try {
    await processor.initialize();
    replies.send(requests.sendPort);
    await for (final request in requests) {
      if (request == null) break;
      try {
        replies.send(_WorkerResult(await processor.process(request as Q)));
      } catch (error, stack) {
        replies.send(_WorkerFailure('$error', '$stack'));
      }
    }
  } catch (error, stack) {
    replies.send(_WorkerFailure('$error', '$stack'));
  } finally {
    requests.close();
    await processor.dispose();
  }
}

class _WorkerResult<T> {
  const _WorkerResult(this.value);
  final T value;
}

class _WorkerFailure {
  const _WorkerFailure(this.error, this.stack);
  final String error;
  final String stack;
}
