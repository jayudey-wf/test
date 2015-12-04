Future debug(Configuration config, Engine engine, Reporter reporter,
    LoadSuite loadSuite) async {
  // Make the underlying suite null so that the engine doesn't start running
  // it immediately.
  _engine.suiteSink.add(loadSuite.changeSuite((_) => null));

  var suite = await loadSuite.suite;
  if (suite == null) return;

  var debugger = new _Debugger(config, reporter, suite);
  try {
    await debugger._pause();
    if (_closed) return;

    debugger._listen();
    _engine.suiteSink.add(suite);
    await _engine.onIdle.first;
  } finally {
    debugger._close();
  }
}

class _Debugger {
  final Configuration _config;

  final Reporter _reporter;

  final RunnerSuite _suite;

  StreamSubscription<bool> _onDebuggingSubscription;

  bool _canDebug =>
      _suite.platform != null && _suite.platform != TestPlatform.vm;

  _Debugger(this._config, this._reporter, this._suite);

  Future _pause() async {
    if (_suite.platform == null) return;
    if (_suite.platform == TestPlatform.vm) return;

    try {
      _reporter.pause();

      var bold = _config.color ? '\u001b[1m' : '';
      var yellow = _config.color ? '\u001b[33m' : '';
      var noColor = _config.color ? '\u001b[0m' : '';
      print('');

      if (_suite.platform.isDartVM) {
        var url = _suite.environment.observatoryUrl;
        if (url == null) {
          print("${yellow}Observatory URL not found. Make sure you're using "
              "${_suite.platform.name} 1.11 or later.$noColor");
        } else {
          print("Observatory URL: $bold$url$noColor");
        }
      }

      if (_suite.platform.isHeadless) {
        var url = _suite.environment.remoteDebuggerUrl;
        if (url == null) {
          print("${yellow}Remote debugger URL not found.$noColor");
        } else {
          print("Remote debugger URL: $bold$url$noColor");
        }
      }

      var buffer = new StringBuffer(
          "${bold}The test runner is paused.${noColor} ");
      if (!_suite.platform.isHeadless) {
        buffer.write("Open the dev console in ${_suite.platform} ");
      } else {
        buffer.write("Open the remote debugger ");
      }
      if (_suite.platform.isDartVM) buffer.write("or the Observatory ");

      buffer.write("and set breakpoints. Once you're finished, return to this "
          "terminal and press Enter.");

      print(wordWrap(buffer.toString()));

      await inCompletionOrder([
        _suite.environment.displayPause(),
        cancelableNext(stdinLines)
      ]).first;
    } finally {
      _reporter.resume();
    }
  }

  void _listen() {
    _suite.onDebugging.listen((debugging) {
      if (debugging) {
        _onDebugging();
      } else {
        _onNotDebugging();
      }
    });
  }

  void _onDebugging(bool debugging) {
    _reporter.pause();
  }

  void _close() {
    _onDebuggingSubscription.cancel();
  }
}
