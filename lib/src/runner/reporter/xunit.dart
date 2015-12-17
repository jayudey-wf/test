// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.runner.reporter.xunit;

import 'dart:async';

import '../../backend/live_test.dart';
import '../../backend/state.dart';
import '../../backend/group.dart';
import '../../frontend/expect.dart';
import '../../utils.dart';
import '../engine.dart';
import '../load_suite.dart';
import '../reporter.dart';

class XunitFailureResult {
  String name;
  String stack;

  XunitFailureResult(this.name, this.stack);
}

class XunitTestResult {
  int beginningTime;
  int endTime;
  Map error = {};
  String name;
  String path;
  bool skipped = false;
  String skipReason;

  XunitTestResult(this.name, this.path, this.beginningTime);
}

class XunitTestSuite {
  int errored = 0;
  int failed = 0;
  int skipped = 0;
  List testResults = [];
  int tests = 0;

  add(XunitTestResult test) {
    testResults.add(test);
  }
}

/// A reporter that returns xunit compatible output.

class XunitReporter implements Reporter {
  /// The engine used to run the tests.
  final Engine _engine;

  /// A stopwatch that tracks the duration of the full run.
  final _stopwatch = new Stopwatch();

  /// Whether we've started [_stopwatch].
  ///
  /// We can't just use `_stopwatch.isRunning` because the stopwatch is stopped
  /// when the reporter is paused.
  var _stopwatchStarted = false;

  /// Whether the reporter is paused.
  var _paused = false;

  /// The set of all subscriptions to various streams.
  final _subscriptions = new Set<StreamSubscription>();

  /// Record of all tests run.
  Map _testCases = {};

  /// Number of failures that occur during the test run.
  int _failureCount = 0;

  /// Number of errors that occur during the test run.
  int _errorCount = 0;

  /// Map containing Xunit hierarchy.
  Map _groupStructure = {};

  /// Watches the tests run by [engine] and records its results.
  static XunitReporter watch(Engine engine, {bool verboseTrace: false}) {
    return new XunitReporter._(engine, verboseTrace: verboseTrace);
  }

  XunitReporter._(this._engine, {bool verboseTrace: false}) {
    _subscriptions.add(_engine.onTestStarted.listen(_onTestStarted));

    /// Convert the future to a stream so that the subscription can be paused or
    /// canceled.
    _subscriptions.add(_engine.success.asStream().listen(_onDone));
  }

  void pause() {
    if (_paused) return;
    _paused = true;

    _stopwatch.stop();

    for (var subscription in _subscriptions) {
      subscription.pause();
    }
  }

  void resume() {
    if (!_paused) return;
    if (_stopwatchStarted) _stopwatch.start();

    for (var subscription in _subscriptions) {
      subscription.resume();
    }
  }

  void cancel() {
    for (var subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// A callback called when the engine begins running [liveTest].
  void _onTestStarted(LiveTest liveTest) {
    if (liveTest.suite is! LoadSuite) {
      if (!_stopwatch.isRunning) _stopwatch.start();

      _subscriptions.add(liveTest.onStateChange
          .listen((state) => _onStateChange(liveTest, state)));
    }

    _subscriptions.add(liveTest.onError
        .listen((error) => _onError(liveTest, error.error, error.stackTrace)));

    _subscriptions.add(liveTest.onPrint.listen((line) {}));
  }

  /// Return an ordered list of groups that [liveTest] belongs to
  List _orderedGroupList(List<Group> listOfGroups) {
    List separatedList = [];
    if (listOfGroups.length > 1) {
      separatedList.add(listOfGroups[1].name);
      for (int i = 2; i < listOfGroups.length; i++) {
        separatedList.add(listOfGroups[i]
            .name
            .replaceAll(listOfGroups[i - 1].name, '')
            .trim());
      }
    }
    return separatedList;
  }

  /// A callback called when [liveTest]'s state becomes [state].
  void _onStateChange(LiveTest liveTest, State state) {
    if (state.status != Status.complete) {
      if (state.status == Status.running &&
          !_testCases.containsKey(liveTest.test)) {
        String testName = liveTest.individualName;
        testName = testName.replaceAll('&', '&amp;');
        testName = testName.replaceAll('<', '&lt;');
        testName = testName.replaceAll('>', '&gt;');
        testName = testName.replaceAll('"', '&quot;');
        testName = testName.replaceAll("'", '&apos;');

        _testCases[liveTest] = new XunitTestResult(
            testName, liveTest.suite.path, _stopwatch.elapsedMilliseconds);
        List listOfGroups = _orderedGroupList(liveTest.groups);
        Map listGroup = _groupStructure;

        listOfGroups.forEach((elem) {
          if (!listGroup.containsKey(elem)) {
            listGroup[elem] = {'testResults': new XunitTestSuite()};
          }
          listGroup = listGroup[elem];
        });

        listGroup['testResults'] ??= new XunitTestSuite();

        listGroup['testResults'].add(_testCases[liveTest]);
      }
      return;
    }

    _testCases[liveTest].endTime = _stopwatch.elapsedMilliseconds;

    if (liveTest.test.metadata.skip) {
      _testCases[liveTest].skipped = true;
      if (liveTest.test.metadata.skipReason != null) {
        _testCases[liveTest].skipReason = liveTest.test.metadata.skipReason;
      }
    }
  }

  /// A callback called when [liveTest] throws [error].
  void _onError(LiveTest liveTest, error, StackTrace stackTrace) {
    if (liveTest.state.status != Status.complete) return;
    if (_testCases[liveTest].error.isEmpty) {
      if (error is TestFailure) {
        _failureCount++;
        _testCases[liveTest].error['failure'] = true;
      } else {
        _errorCount++;
        _testCases[liveTest].error['failure'] = false;
      }
    }
    String body = terseChain(stackTrace).toString().trim();
    body = body.replaceAll('<', '&lt;');
    body = body.replaceAll('>', '&gt;');
    String name = error.toString().replaceAll('\n', '');
    _testCases[liveTest].error['list'] ??= [];
    _testCases[liveTest].error['list'].add(new XunitFailureResult(name, body));
  }

  /// A method used to format individual testcases
  String _formatTestResults(List list, int counter) {
    String testResults = '';
    list.forEach((XunitTestResult test) {
      String individualTest = '';
      if (test.error.isEmpty) {
        individualTest +=
            '<testcase classname=\"${test.path}\" name=\"${test.name}\" time=\"${test.endTime - test.beginningTime}\"> </testcase>';
      } else {
        individualTest +=
            '<testcase classname=\"${test.path}\" name=\"${test.name}\">';
        if (test.error['failure']) {
          test.error['list'].forEach((XunitFailureResult testFailure) {
            individualTest += '\n' +
                ' ' * (counter + 4) +
                '<failure message="${testFailure.name}">';
            testFailure.stack.split('\n').forEach((line) {
              individualTest += '\n' + ' ' * (counter + 6) + line;
            });
            individualTest += '\n' + ' ' * (counter + 4) + '</failure>';
          });
        } else {
          test.error['list'].forEach((XunitFailureResult testError) {
            individualTest += '\n' +
                ' ' * (counter + 4) +
                '<error message="${testError.name}">';
            testError.stack.split('\n').forEach((line) {
              individualTest += '\n' + ' ' * (counter + 6) + line;
            });
            individualTest += '\n' + ' ' * (counter + 4) + '</error>';
          });
        }
        individualTest += '\n' + ' ' * (counter + 2) + '</testcase>';
      }
      if (test.skipReason != null) {
        individualTest += '\n' +
            ' ' * (counter + 4) +
            '<skipped message="${test.skipReason}"/>';
      }
      testResults += '\n' + ' ' * (counter + 2) + individualTest;
    });
    return testResults;
  }

  /// Calculate the test totals for a suite and its children
  XunitTestSuite _suiteResults(Map group, XunitTestSuite suite) {
    Map groupStructure = group;
    XunitTestSuite currentSuite = suite;

    groupStructure.forEach((key, value) {
      if (key == 'testResults') {
        value.testResults.forEach((element) {
          currentSuite.tests++;
          if (element.skipped) {
            currentSuite.skipped++;
          }
          if (element.error.isNotEmpty) {
            if (element.error['failure'] == true) {
              currentSuite.failed++;
            } else {
              currentSuite.errored++;
            }
          }
        });
      } else {
        _suiteResults(groupStructure[key], currentSuite);
      }
    });

    return suite;
  }

  /// Format testsuite headings
  String _formatTestSuiteHeading(Map group) {
    XunitTestSuite suite = _suiteResults(group, group['testResults']);

    String suiteHeading = '';
    if (suite.tests > 0) {
      suiteHeading += 'tests="${suite.tests}" ';
    }
    if (suite.failed > 0) {
      suiteHeading += 'failures="${suite.failed}" ';
    }
    if (suite.errored > 0) {
      suiteHeading += 'errors="${suite.errored}" ';
    }
    if (suite.skipped > 0) {
      suiteHeading += 'skipped="${suite.skipped}" ';
    }
    return suiteHeading.trimRight();
  }

  /// A method used to create a nested xml hierarchy
  String _formatXmlHierarchy(Map xmlMap, {int counter: 0}) {
    counter++;
    String result = "";
    xmlMap.keys.forEach((elem) {
      if (xmlMap[elem] is Map) {
        var space = ' ';
        result += space * counter +
            '<testsuite name="$elem" ${_formatTestSuiteHeading(xmlMap[elem])}>${_formatTestResults(xmlMap[elem]["testResults"].testResults, counter)}\n';
        result += _formatXmlHierarchy(xmlMap[elem], counter: counter);
        result += space * counter + '</testsuite>';
        if (counter > 0) {
          result += '\n';
        }
      }
    });
    return result;
  }

  /// A callback called when the engine is finished running tests.
  ///
  /// [success] will be `true` if all tests passed, `false` if some tests
  /// failed, and `null` if the engine was closed prematurely.
  void _onDone(bool success) {
    // A null success value indicates that the engine was closed before the
    // tests finished running, probably because of a signal from the user, in
    // which case we shouldn't print summary information.
    if (success == null) return;

    print('<?xml version="1.0" encoding="UTF-8" ?>');
    print(
        '<testsuite name="All tests" tests="${_engine.passed.length + _engine.skipped.length +_engine.failed.length}" '
        'errors="$_errorCount" failures="$_failureCount" skipped="${_engine.skipped.length}">');

    if (_groupStructure['testResults']?.testResults == null) {
      print(_formatXmlHierarchy(_groupStructure).trimRight());
    }
    if (_groupStructure['testResults']?.testResults?.isNotEmpty) {
      print(_formatTestResults(_groupStructure['testResults'].testResults, 1)
          .substring(1));
    }

    print('</testsuite>');

    if (_engine.liveTests.isEmpty) {
      print("No tests ran.");
    }
  }
}
