// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test_runner.browser_test_runner;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart_binaries.dart';
import 'dart_project.dart';
import 'test_configuration.dart';
import 'test_execution_result.dart';
import 'test_runner.dart';
import 'browser_test_runner_code_generator.dart';
import 'util.dart';

/// Runs Dart tests that can be run in a web browser.
class BrowserTestRunner extends TestRunner {

  /// Port to be used by the [WebServer] serving the test files.
  // TODO: randomize port if already used.
  static const int _WEB_SERVER_PORT = 7478;

  /// Host to be used by the [WebServer] serving the test files.
  static const String _WEB_SERVER_HOST = "127.0.0.1";

  /// Points to the [Completer]s that will indicate if pub serve is ready for a
  /// given project absolute path.
  static final Map<String, Completer> _pubServerCompleters = new Map();

  /// Pointers to all Dart SDK binaries.
  final DartBinaries dartBinaries;

  /// Pointers to the Dart Project containing the tests.
  final DartProject dartProject;

  /// Constructor.
  BrowserTestRunner(this.dartBinaries, this.dartProject);

  @override
  Future<TestExecutionResult> runTest(TestConfiguration test) {
    Completer<TestExecutionResult> completer = new Completer();

    // Create the temporary generated test files.
    BrowserTestRunnerCodeGenerator codeGenerator =
        new BrowserTestRunnerCodeGenerator(dartProject);
    Future htmlFileFuture = codeGenerator.createTestHtmlFile(
        test.testFileName, (test.testType as BrowserTest).htmlFilePath);
    Future dartFileFuture = codeGenerator.createTestDartFile(test.testFileName);

    // Start the Web Server and run the test.
    Future httpServer = _startHttpServer();

    // Runs the Web Test in Content Shell when the files have been created and
    // when all the test files have been generated.
    Future.wait([htmlFileFuture, dartFileFuture, httpServer]).then((_) {

      String testUrl = _buildBrowserTestUrl(test.testFileName);

      String testOutput = "";
      String testErrorOutput = "";

      Process.start(dartBinaries.contentShellBin,
                ["--args", "--dump-render-tree",
                 "--disable-gpu", testUrl], runInShell: false)
             .then((Process testProcessResult) {

        var success = false;

        testProcessResult.stdout.transform(new Utf8Decoder())
            .transform(new LineSplitter())
            .listen((String line) {
              if (line == "#CRASHED") {
                throw new Exception("Error: Content shell crashed.");
              } else  if (line == "PASS"){
                testOutput = "$testOutput\n$line";
                success = true;
              } else if (line == "#EOF") {
                TestExecutionResult result = new TestExecutionResult(test,
                    success: success,
                    testOutput: testOutput,
                    testErrorOutput: testErrorOutput);
                completer.complete(result);
                testProcessResult.kill();
              } else if (line != "CONSOLE MESSAGE: Warning: The "
                  "unittestConfiguration has already been set. New "
                  "unittestConfiguration ignored."
                  && line != "Content-Type: text/plain"
                  && line != "#READY"
                  && line != "unittest-suite-wait-for-done") {
                testOutput = "$testOutput\n$line";
              }
        });


        testProcessResult.stderr.transform(new Utf8Decoder())
            .transform(new LineSplitter())
            .listen(
                (String line) => testErrorOutput == "$testErrorOutput\n$line");

      });

      // TODO: enable code coverage data gathering when
      //       https://code.google.com/p/dart/issues/detail?id=20293 is fixed.
      // import 'coverage.dart'
      //startCodeCoverageListener();
    });



    return completer.future;
  }

  /// Starts the HTTP server (pub serve in our case) that's serving the test
  /// files. The Future completes when pub serve is ready to serve files.
  Future _startHttpServer() {

    // Check if there is already pub serve running (or being started) for this
    // project.
    Completer pubServerCompleter =
        _pubServerCompleters[dartProject.testDirectory.path];

    if (pubServerCompleter != null) {
      return pubServerCompleter.future;
    }

    // Start pub serve to serve the test directory of the project.
    pubServerCompleter = new Completer();
    _pubServerCompleters[dartProject.testDirectory.path] = pubServerCompleter;

    Process.start(dartBinaries.pubBin,
                  ["serve", "test", "--port", "$_WEB_SERVER_PORT"],
                  workingDirectory: dartProject.projectPath).then(
        (Process process) {
          process.stdout.transform(new Utf8Decoder())
                        .transform(new LineSplitter())
                        .listen(
              (String line) {
                if (line.contains("Build completed")
                    && !pubServerCompleter.isCompleted) {
                  pubServerCompleter.complete();
                }
              });
        });

    return pubServerCompleter.future;
  }

  /// Returns the URL that will run the given browser test file.
  String _buildBrowserTestUrl(String testFileName) {
    return "http://$_WEB_SERVER_HOST:$_WEB_SERVER_PORT/"
        "${GENERATED_TEST_FILES_DIR_NAME}/"
        "${testFileName.replaceFirst(new RegExp(r"\.dart$"), ".html")}";
  }
}


/// Template of a Default HTML file for Browser unittest files that will
/// start the tests in the Dart file written instead of the `{{test_file_name}}`
/// placeholder.
const String _BROWSER_TEST_HTML_FILE_TEMPLATE = '''
<!-- Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
for details. All rights reserved. Use of this source code is governed by a
BSD-style license that can be found in the LICENSE file. -->

<!DOCTYPE html>

<html>
  <head>
    <title>Default Web Test HTML file</title>
    <meta charset="utf-8" />
    <meta name="description" content="Runs a Web test" />
  </head>
  <body>
    <!-- Scripts -->
    <script type="application/dart" src="/{{test_file_name}}"></script>
    <script type="text/javascript" src="/packages/unittest/test_controller.js"></script>
  </body>
</html>
''';