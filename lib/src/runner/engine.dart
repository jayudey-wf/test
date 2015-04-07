// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.runner.engine;

import 'dart:async';
import 'dart:collection';

import 'package:pool/pool.dart';

import '../backend/live_test.dart';
import '../backend/state.dart';
import '../backend/suite.dart';
import '../utils.dart';

/// An [Engine] manages a run that encompasses multiple test suites.
///
/// The current status of every test is visible via [liveTests]. [onTestStarted]
/// can also be used to be notified when a test is about to be run.
///
/// Suites will be run in the order they're provided to [new Engine]. Tests
/// within those suites will likewise be run in the order of [Suite.tests].
class Engine {
  /// Whether [run] has been called yet.
  var _runCalled = false;

  /// Whether [close] has been called.
  var _closed = false;

  /// A pool that limits the number of test suites running concurrently.
  final Pool _pool;

  /// An unmodifiable list of tests to run.
  ///
  /// These are [LiveTest]s, representing the in-progress state of each test.
  /// Tests that have not yet begun running are marked [Status.pending]; tests
  /// that have finished are marked [Status.complete].
  ///
  /// [LiveTest.run] must not be called on these tests.
  List<LiveTest> get liveTests =>
      new UnmodifiableListView(flatten(_liveTestsBySuite));

  final List<List<LiveTest>> _liveTestsBySuite;

  /// A stream that emits each [LiveTest] as it's about to start running.
  ///
  /// This is guaranteed to fire before [LiveTest.onStateChange] first fires.
  Stream<LiveTest> get onTestStarted => _onTestStartedController.stream;
  final _onTestStartedController = new StreamController<LiveTest>.broadcast();

  /// Creates an [Engine] that will run all tests in [suites].
  Engine(Iterable<Suite> suites, {int concurrency})
      : _liveTestsBySuite = suites.map((suite) =>
            suite.tests.map((test) => test.load(suite)).toList()).toList(),
        _pool = new Pool(concurrency == null ? 1 : concurrency);

  /// Runs all tests in all suites defined by this engine.
  ///
  /// This returns `true` if all tests succeed, and `false` otherwise. It will
  /// only return once all tests have finished running.
  Future<bool> run() {
    if (_runCalled) {
      throw new StateError("Engine.run() may not be called more than once.");
    }
    _runCalled = true;

    return Future.wait(_liveTestsBySuite.map((suite) {
      return _pool.withResource(() {
        if (_closed) return null;

        return Future.forEach(suite, (liveTest) {
          if (_closed) return new Future.value();
          _onTestStartedController.add(liveTest);

          // First, schedule a microtask to ensure that [onTestStarted] fires
          // before the first [LiveTest.onStateChange] event. Once the test
          // finishes, use [new Future] to do a coarse-grained event loop pump
          // to avoid starving the DOM or other non-microtask events.
          return new Future.microtask(liveTest.run)
              .then((_) => new Future(() {}));
        });
      });
    })).then((_) =>
        liveTests.every((liveTest) => liveTest.state.result == Result.success));
  }

  /// Signals that the caller is done paying attention to test results and the
  /// engine should release any resources it has allocated.
  ///
  /// Any actively-running tests are also closed. VM tests are allowed to finish
  /// running so that any modifications they've made to the filesystem can be
  /// cleaned up.
  Future close() {
    _closed = true;
    return Future.wait(liveTests.map((liveTest) => liveTest.close()));
  }
}
