// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:analysis_server/src/lsp/handlers/handlers.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/transform_set_parser.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/instrumentation/instrumentation.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_content_cache.dart';
import 'package:analyzer/src/dart/analysis/performance_logger.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/lint/linter.dart';
import 'package:analyzer/src/lint/pub.dart';
import 'package:analyzer/src/manifest/manifest_validator.dart';
import 'package:analyzer/src/pubspec/pubspec_validator.dart';
import 'package:analyzer/src/task/options.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer/src/workspace/bazel.dart';
import 'package:analyzer/src/workspace/bazel_watcher.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' as protocol;
import 'package:analyzer_plugin/utilities/analyzer_converter.dart';
import 'package:path/path.dart' as path;
import 'package:watcher/watcher.dart';
import 'package:yaml/yaml.dart';

/// Enables watching of files generated by Bazel.
///
/// TODO(michalt): This is a temporary flag that we use to disable this
/// functionality due its performance issues. We plan to benchmark and optimize
/// it and re-enable it everywhere.
/// Not private to enable testing.
/// NB: If you set this to `false` remember to disable the
/// `test/integration/serve/bazel_changes_test.dart`.
var experimentalEnableBazelWatching = true;

/// Class that maintains a mapping from included/excluded paths to a set of
/// folders that should correspond to analysis contexts.
abstract class ContextManager {
  /// Get the callback interface used to create, destroy, and update contexts.
  ContextManagerCallbacks get callbacks;

  /// Set the callback interface used to create, destroy, and update contexts.
  set callbacks(ContextManagerCallbacks value);

  /// A table mapping [Folder]s to the [AnalysisDriver]s associated with them.
  Map<Folder, AnalysisDriver> get driverMap;

  /// Return the list of excluded paths (folders and files) most recently passed
  /// to [setRoots].
  List<String> get excludedPaths;

  /// Return the list of included paths (folders and files) most recently passed
  /// to [setRoots].
  List<String> get includedPaths;

  /// Return the existing analysis context that should be used to analyze the
  /// given [path], or `null` if the [path] is not analyzed in any of the
  /// created analysis contexts.
  DriverBasedAnalysisContext? getContextFor(String path);

  /// Return the [AnalysisDriver] for the "innermost" context whose associated
  /// folder is or contains the given path.  ("innermost" refers to the nesting
  /// of contexts, so if there is a context for path /foo and a context for
  /// path /foo/bar, then the innermost context containing /foo/bar/baz.dart is
  /// the context for /foo/bar.)
  ///
  /// If no driver contains the given path, `null` is returned.
  AnalysisDriver? getDriverFor(String path);

  /// Return `true` if the file or directory with the given [path] will be
  /// analyzed in one of the analysis contexts.
  bool isAnalyzed(String path);

  /// Rebuild the set of contexts from scratch based on the data last sent to
  /// [setRoots].
  Future<void> refresh();

  /// Change the set of paths which should be used as starting points to
  /// determine the context directories.
  Future<void> setRoots(List<String> includedPaths, List<String> excludedPaths);
}

/// Callback interface used by [ContextManager] to (a) request that contexts be
/// created, destroyed or updated, (b) inform the client when "pub list"
/// operations are in progress, and (c) determine which files should be
/// analyzed.
///
/// TODO(paulberry): eliminate this interface, and instead have [ContextManager]
/// operations return data structures describing how context state should be
/// modified.
abstract class ContextManagerCallbacks {
  /// Called after analysis contexts are created, usually when new analysis
  /// roots are set, or after detecting a change that required rebuilding
  /// the set of analysis contexts.
  void afterContextsCreated();

  /// Called after analysis contexts are destroyed.
  void afterContextsDestroyed();

  /// An [event] was processed, so analysis state might be different now.
  void afterWatchEvent(WatchEvent event);

  /// The given [file] was removed.
  void applyFileRemoved(String file);

  /// Sent the given watch [event] to any interested plugins.
  void broadcastWatchEvent(WatchEvent event);

  /// Add listeners to the [driver]. This must be the only listener.
  ///
  /// TODO(scheglov) Just pass results in here?
  void listenAnalysisDriver(AnalysisDriver driver);

  /// The `pubspec.yaml` at [path] was added/modified.
  void pubspecChanged(String path);

  /// The `pubspec.yaml` at [path] was removed.
  void pubspecRemoved(String path);

  /// Record error information for the file with the given [path].
  void recordAnalysisErrors(String path, List<protocol.AnalysisError> errors);
}

/// Class that maintains a mapping from included/excluded paths to a set of
/// folders that should correspond to analysis contexts.
class ContextManagerImpl implements ContextManager {
  /// The [ResourceProvider] using which paths are converted into [Resource]s.
  final ResourceProvider resourceProvider;

  /// The manager used to access the SDK that should be associated with a
  /// particular context.
  final DartSdkManager sdkManager;

  /// The path to the package config file override.
  /// If `null`, then the default discovery mechanism is used.
  final String? packagesFile;

  /// The storage for cached results.
  final ByteStore _byteStore;

  /// The cache of file contents shared between context of the collection.
  final FileContentCache _fileContentCache;

  /// The logger used to create analysis contexts.
  final PerformanceLog _performanceLog;

  /// The scheduler used to create analysis contexts, and report status.
  final AnalysisDriverScheduler _scheduler;

  /// The current set of analysis contexts, or `null` if the context roots have
  /// not yet been set.
  AnalysisContextCollectionImpl? _collection;

  /// The context used to work with file system paths.
  path.Context pathContext;

  /// The list of excluded paths (folders and files) most recently passed to
  /// [setRoots].
  @override
  List<String> excludedPaths = <String>[];

  /// The list of included paths (folders and files) most recently passed to
  /// [setRoots].
  @override
  List<String> includedPaths = <String>[];

  /// The instrumentation service used to report instrumentation data.
  final InstrumentationService _instrumentationService;

  @override
  ContextManagerCallbacks callbacks = NoopContextManagerCallbacks();

  @override
  final Map<Folder, AnalysisDriver> driverMap =
      HashMap<Folder, AnalysisDriver>();

  /// Stream subscription we are using to watch each analysis root directory for
  /// changes.
  final Map<Folder, StreamSubscription<WatchEvent>> changeSubscriptions =
      <Folder, StreamSubscription<WatchEvent>>{};

  /// For each folder, stores the subscription to the Bazel workspace so that we
  /// can establish watches for the generated files.
  final bazelSearchSubscriptions =
      <Folder, StreamSubscription<BazelSearchInfo>>{};

  /// The watcher service running in a separate isolate to watch for changes
  /// to files generated by Bazel.
  ///
  /// Might be `null` if watching Bazel files is not enabled.
  BazelFileWatcherService? bazelWatcherService;

  /// The subscription to changes in the files watched by [bazelWatcherService].
  ///
  /// Might be `null` if watching Bazel files is not enabled.
  StreamSubscription<List<WatchEvent>>? bazelWatcherSubscription;

  /// For each [Folder] store which files are being watched. This allows us to
  /// clean up when we destroy a context.
  final bazelWatchedPathsPerFolder = <Folder, _BazelWatchedFiles>{};

  /// Information about the current/last queued context rebuild.
  ///
  /// This is used when a new build is requested to cancel any in-progress
  /// rebuild and wait for it to terminate before starting the next.
  final _CancellingTaskQueue currentContextRebuild = _CancellingTaskQueue();

  ContextManagerImpl(
      this.resourceProvider,
      this.sdkManager,
      this.packagesFile,
      this._byteStore,
      this._fileContentCache,
      this._performanceLog,
      this._scheduler,
      this._instrumentationService,
      {required bool enableBazelWatcher})
      : pathContext = resourceProvider.pathContext {
    if (enableBazelWatcher) {
      bazelWatcherService = BazelFileWatcherService(_instrumentationService);
      bazelWatcherSubscription = bazelWatcherService!.events
          .listen((events) => _handleBazelWatchEvents(events));
    }
  }

  @override
  DriverBasedAnalysisContext? getContextFor(String path) {
    try {
      return _collection?.contextFor(path);
    } on StateError {
      return null;
    }
  }

  @override
  AnalysisDriver? getDriverFor(String path) {
    return getContextFor(path)?.driver;
  }

  @override
  bool isAnalyzed(String path) {
    var collection = _collection;
    if (collection == null) {
      return false;
    }

    return collection.contexts.any(
      (context) => context.contextRoot.isAnalyzed(path),
    );
  }

  /// Starts (an asynchronous) rebuild of analysis contexts.
  @override
  Future<void> refresh() async {
    await _createAnalysisContexts();
  }

  /// Updates the analysis roots and waits for the contexts to rebuild.
  ///
  /// If the roots have not changed, exits early without performing any work.
  @override
  Future<void> setRoots(
      List<String> includedPaths, List<String> excludedPaths) async {
    if (_rootsAreUnchanged(includedPaths, excludedPaths)) {
      return;
    }

    this.includedPaths = includedPaths;
    this.excludedPaths = excludedPaths;

    await _createAnalysisContexts();
  }

  /// Use the given analysis [driver] to analyze the content of the analysis
  /// options file at the given [path].
  void _analyzeAnalysisOptionsYaml(AnalysisDriver driver, String path) {
    var convertedErrors = const <protocol.AnalysisError>[];
    try {
      var content = _readFile(path);
      var lineInfo = LineInfo.fromContent(content);
      var errors = analyzeAnalysisOptions(
        resourceProvider.getFile(path).createSource(),
        content,
        driver.sourceFactory,
        driver.currentSession.analysisContext.contextRoot.root.path,
      );
      var converter = AnalyzerConverter();
      convertedErrors = converter.convertAnalysisErrors(errors,
          lineInfo: lineInfo, options: driver.analysisOptions);
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.recordAnalysisErrors(path, convertedErrors);
  }

  /// Use the given analysis [driver] to analyze the content of the
  /// AndroidManifest file at the given [path].
  void _analyzeAndroidManifestXml(AnalysisDriver driver, String path) {
    var convertedErrors = const <protocol.AnalysisError>[];
    try {
      var content = _readFile(path);
      var validator =
          ManifestValidator(resourceProvider.getFile(path).createSource());
      var lineInfo = LineInfo.fromContent(content);
      var errors = validator.validate(
          content, driver.analysisOptions.chromeOsManifestChecks);
      var converter = AnalyzerConverter();
      convertedErrors = converter.convertAnalysisErrors(errors,
          lineInfo: lineInfo, options: driver.analysisOptions);
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.recordAnalysisErrors(path, convertedErrors);
  }

  /// Use the given analysis [driver] to analyze the content of the
  /// data file at the given [path].
  void _analyzeFixDataYaml(AnalysisDriver driver, String path) {
    var convertedErrors = const <protocol.AnalysisError>[];
    try {
      var file = resourceProvider.getFile(path);
      var packageName = file.parent.parent.shortName;
      var content = _readFile(path);
      var errorListener = RecordingErrorListener();
      var errorReporter = ErrorReporter(
        errorListener,
        file.createSource(),
        isNonNullableByDefault: false,
      );
      var parser = TransformSetParser(errorReporter, packageName);
      parser.parse(content);
      var converter = AnalyzerConverter();
      convertedErrors = converter.convertAnalysisErrors(errorListener.errors,
          lineInfo: LineInfo.fromContent(content),
          options: driver.analysisOptions);
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.recordAnalysisErrors(path, convertedErrors);
  }

  /// Use the given analysis [driver] to analyze the content of the pubspec file
  /// at the given [path].
  void _analyzePubspecYaml(AnalysisDriver driver, String path) {
    var convertedErrors = const <protocol.AnalysisError>[];
    try {
      var content = _readFile(path);
      var node = loadYamlNode(content);
      if (node is YamlMap) {
        var validator = PubspecValidator(
            resourceProvider, resourceProvider.getFile(path).createSource());
        var lineInfo = LineInfo.fromContent(content);
        var errors = validator.validate(node.nodes);
        var converter = AnalyzerConverter();
        convertedErrors = converter.convertAnalysisErrors(errors,
            lineInfo: lineInfo, options: driver.analysisOptions);

        if (driver.analysisOptions.lint) {
          var visitors = <LintRule, PubspecVisitor>{};
          for (var linter in driver.analysisOptions.lintRules) {
            if (linter is LintRule) {
              var visitor = linter.getPubspecVisitor();
              if (visitor != null) {
                visitors[linter] = visitor;
              }
            }
          }

          if (visitors.isNotEmpty) {
            var sourceUri = resourceProvider.pathContext.toUri(path);
            var pubspecAst = Pubspec.parse(content,
                sourceUrl: sourceUri, resourceProvider: resourceProvider);
            var listener = RecordingErrorListener();
            var reporter = ErrorReporter(listener,
                resourceProvider.getFile(path).createSource(sourceUri),
                isNonNullableByDefault: false);
            for (var entry in visitors.entries) {
              entry.key.reporter = reporter;
              pubspecAst.accept(entry.value);
            }
            if (listener.errors.isNotEmpty) {
              convertedErrors.addAll(converter.convertAnalysisErrors(
                  listener.errors,
                  lineInfo: lineInfo,
                  options: driver.analysisOptions));
            }
          }
        }
      }
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.recordAnalysisErrors(path, convertedErrors);
  }

  void _checkForAndroidManifestXmlUpdate(String path) {
    if (file_paths.isAndroidManifestXml(pathContext, path)) {
      var driver = getDriverFor(path);
      if (driver != null) {
        _analyzeAndroidManifestXml(driver, path);
      }
    }
  }

  void _checkForFixDataYamlUpdate(String path) {
    if (file_paths.isFixDataYaml(pathContext, path)) {
      var driver = getDriverFor(path);
      if (driver != null) {
        _analyzeFixDataYaml(driver, path);
      }
    }
  }

  /// Recreates all analysis contexts.
  ///
  /// If an existing rebuild is in progress, it will be cancelled and this
  /// rebuild will occur only once it has exited.
  ///
  /// Returns a [Future] that completes once the requested rebuild completes.
  Future<void> _createAnalysisContexts() async {
    /// A helper that performs a context rebuild while monitoring the included
    /// paths for changes until the contexts file watchers are ready.
    ///
    /// If changes are detected during the rebuild, the rebuild will be
    /// restarted.
    Future<void> performContextRebuildGuarded(
      CancellationToken cancellationToken,
    ) async {
      /// A helper that performs the context rebuild and waits for all watchers
      /// to be fully initialized.
      Future<void> performContextRebuild() async {
        _destroyAnalysisContexts();
        _fileContentCache.invalidateAll();

        var watchers = <ResourceWatcher>[];
        var collection = _collection = AnalysisContextCollectionImpl(
          includedPaths: includedPaths,
          excludedPaths: excludedPaths,
          byteStore: _byteStore,
          drainStreams: false,
          enableIndex: true,
          performanceLog: _performanceLog,
          resourceProvider: resourceProvider,
          scheduler: _scheduler,
          sdkPath: sdkManager.defaultSdkDirectory,
          packagesFile: packagesFile,
          fileContentCache: _fileContentCache,
        );

        for (var analysisContext in collection.contexts) {
          var driver = analysisContext.driver;

          callbacks.listenAnalysisDriver(driver);

          var rootFolder = analysisContext.contextRoot.root;
          driverMap[rootFolder] = driver;

          var watcher = rootFolder.watch();
          watchers.add(watcher);
          changeSubscriptions[rootFolder] = watcher.changes
              .listen(_handleWatchEvent, onError: _handleWatchInterruption);

          _watchBazelFilesIfNeeded(rootFolder, driver);

          for (var file in analysisContext.contextRoot.analyzedFiles()) {
            if (file_paths.isAndroidManifestXml(pathContext, file)) {
              _analyzeAndroidManifestXml(driver, file);
            } else if (file_paths.isDart(pathContext, file)) {
              driver.addFile(file);
            }
          }

          var optionsFile = analysisContext.contextRoot.optionsFile;
          if (optionsFile != null) {
            _analyzeAnalysisOptionsYaml(driver, optionsFile.path);
          }

          var fixDataYamlFile = rootFolder
              .getChildAssumingFolder('lib')
              .getChildAssumingFile(file_paths.fixDataYaml);
          if (fixDataYamlFile.exists) {
            _analyzeFixDataYaml(driver, fixDataYamlFile.path);
          }

          var pubspecFile =
              rootFolder.getChildAssumingFile(file_paths.pubspecYaml);
          if (pubspecFile.exists) {
            _analyzePubspecYaml(driver, pubspecFile.path);
          }
        }

        // Finally, wait for the new contexts watchers to all become ready so we
        // can ensure they will not lose any future events before we continue.
        await Future.wait(watchers.map((watcher) => watcher.ready));
      }

      /// A helper that returns whether a change to the file at [path] should
      /// restart any in-progress rebuild.
      bool shouldRestartBuild(String path) {
        return file_paths.isDart(pathContext, path) ||
            file_paths.isAnalysisOptionsYaml(pathContext, path) ||
            file_paths.isPubspecYaml(pathContext, path) ||
            file_paths.isDotPackages(pathContext, path) ||
            file_paths.isPackageConfigJson(pathContext, path);
      }

      if (cancellationToken.isCancellationRequested) {
        return;
      }

      // Create temporary watchers before we start the context build so we can
      // tell if any files were modified while waiting for the "real" watchers to
      // become ready and start the process again.
      final temporaryWatchers = includedPaths
          .map((path) => resourceProvider.getResource(path))
          .map((resource) => resource.watch())
          .toList();

      // If any watcher picks up an important change while we're running the
      // rest of this method, we will need to start again.
      var needsBuild = true;
      final temporaryWatcherSubscriptions = temporaryWatchers
          .map((watcher) => watcher.changes.listen((event) {
                if (shouldRestartBuild(event.path)) {
                  needsBuild = true;
                }
              }))
          .toList();

      try {
        // Ensure all watchers are ready before we begin any rebuild.
        await Future.wait(temporaryWatchers.map((watcher) => watcher.ready));

        // Max number of attempts to rebuild if changes.
        var remainingBuilds = 5;
        while (needsBuild && remainingBuilds-- > 0) {
          // Reset the flag, as we'll only need to rebuild if a temporary
          // watcher fires after this point.
          needsBuild = false;

          if (cancellationToken.isCancellationRequested) {
            return;
          }

          // Attempt a context rebuild. This call will wait for all required
          // watchers to be ready before returning.
          await performContextRebuild();
        }
      } finally {
        // Cancel the temporary watcher subscriptions.
        await Future.wait(
          temporaryWatcherSubscriptions.map((sub) => sub.cancel()),
        );
      }

      if (cancellationToken.isCancellationRequested) {
        return;
      }

      callbacks.afterContextsCreated();
    }

    return currentContextRebuild.queue(performContextRebuildGuarded);
  }

  /// Clean up and destroy the context associated with the given folder.
  void _destroyAnalysisContext(DriverBasedAnalysisContext context) {
    context.driver.dispose();
    var rootFolder = context.contextRoot.root;
    changeSubscriptions.remove(rootFolder)?.cancel();
    var watched = bazelWatchedPathsPerFolder.remove(rootFolder);
    if (watched != null) {
      for (var path in watched.paths) {
        bazelWatcherService!.stopWatching(watched.workspace, path);
      }
      _stopWatchingBazelBinPaths(watched);
    }
    bazelSearchSubscriptions.remove(rootFolder)?.cancel();
    driverMap.remove(rootFolder);
  }

  void _destroyAnalysisContexts() {
    var collection = _collection;
    if (collection != null) {
      for (var analysisContext in collection.contexts) {
        _destroyAnalysisContext(analysisContext);
      }
      callbacks.afterContextsDestroyed();
    }
  }

  List<String> _getPossibleBazelBinPaths(_BazelWatchedFiles watched) => [
        pathContext.join(watched.workspace, 'bazel-bin'),
        pathContext.join(watched.workspace, 'blaze-bin'),
      ];

  /// Establishes watch(es) for the Bazel generated files provided in
  /// [notification].
  ///
  /// Whenever the files change, we trigger re-analysis. This allows us to react
  /// to creation/modification of files that were generated by Bazel.
  void _handleBazelSearchInfo(
      Folder folder, String workspace, BazelSearchInfo info) {
    final bazelWatcherService = this.bazelWatcherService;
    if (bazelWatcherService == null) {
      return;
    }

    var watched = bazelWatchedPathsPerFolder.putIfAbsent(
        folder, () => _BazelWatchedFiles(workspace));
    var added = watched.paths.add(info.requestedPath);
    if (added) bazelWatcherService.startWatching(workspace, info);
  }

  /// Notifies the drivers that a generated Bazel file has changed.
  void _handleBazelWatchEvents(List<WatchEvent> events) {
    // First check if we have any changes to the bazel-*/blaze-* paths.  If
    // we do, we'll simply recreate all contexts to make sure that we follow the
    // correct paths.
    var bazelSymlinkPaths = bazelWatchedPathsPerFolder.values
        .expand((watched) => _getPossibleBazelBinPaths(watched))
        .toSet();
    if (events.any((event) => bazelSymlinkPaths.contains(event.path))) {
      refresh();
      return;
    }

    // If a file was created or removed, the URI resolution is likely wrong.
    // Do as for `package_config.json` changes - recreate all contexts.
    if (events
        .map((event) => event.type)
        .any((type) => type == ChangeType.ADD || type == ChangeType.REMOVE)) {
      refresh();
      return;
    }

    // If we have only changes to generated files, notify drivers.
    for (var driver in driverMap.values) {
      for (var event in events) {
        driver.changeFile(event.path);
      }
    }
  }

  void _handleWatchEvent(WatchEvent event) {
    callbacks.broadcastWatchEvent(event);
    _handleWatchEventImpl(event);
    callbacks.afterWatchEvent(event);
  }

  void _handleWatchEventImpl(WatchEvent event) {
    // Figure out which context this event applies to.
    // TODO(brianwilkerson) If a file is explicitly included in one context
    // but implicitly referenced in another context, we will only send a
    // changeSet to the context that explicitly includes the file (because
    // that's the only context that's watching the file).
    var path = event.path;
    var type = event.type;

    _instrumentationService.logWatchEvent('<unknown>', path, type.toString());

    final isPubspec = file_paths.isPubspecYaml(pathContext, path);
    if (file_paths.isAnalysisOptionsYaml(pathContext, path) ||
        file_paths.isBazelBuild(pathContext, path) ||
        file_paths.isDotPackages(pathContext, path) ||
        file_paths.isPackageConfigJson(pathContext, path) ||
        isPubspec ||
        false) {
      _createAnalysisContexts().then((_) {
        if (isPubspec) {
          if (type == ChangeType.REMOVE) {
            callbacks.pubspecRemoved(path);
          } else {
            callbacks.pubspecChanged(path);
          }
        }
      });

      return;
    }

    var collection = _collection;
    if (collection != null && file_paths.isDart(pathContext, path)) {
      for (var analysisContext in collection.contexts) {
        switch (type) {
          case ChangeType.ADD:
            if (analysisContext.contextRoot.isAnalyzed(path)) {
              analysisContext.driver.addFile(path);
            } else {
              analysisContext.driver.changeFile(path);
            }
            break;
          case ChangeType.MODIFY:
            analysisContext.driver.changeFile(path);
            break;
          case ChangeType.REMOVE:
            analysisContext.driver.removeFile(path);
            break;
        }
      }
    }

    switch (type) {
      case ChangeType.ADD:
      case ChangeType.MODIFY:
        _checkForAndroidManifestXmlUpdate(path);
        _checkForFixDataYamlUpdate(path);
        break;
      case ChangeType.REMOVE:
        callbacks.applyFileRemoved(path);
        break;
    }
  }

  /// On windows, the directory watcher may overflow, and we must recover.
  void _handleWatchInterruption(dynamic error, StackTrace stackTrace) {
    // We've handled the error, so we only have to log it.
    _instrumentationService
        .logError('Watcher error; refreshing contexts.\n$error\n$stackTrace');
    // TODO(mfairhurst): Optimize this, or perhaps be less complete.
    refresh();
  }

  /// Read the contents of the file at the given [path], or throw an exception
  /// if the contents cannot be read.
  String _readFile(String path) {
    return resourceProvider.getFile(path).readAsStringSync();
  }

  /// Checks whether the current roots were built using the same paths as
  /// [includedPaths]/[excludedPaths].
  bool _rootsAreUnchanged(
      List<String> includedPaths, List<String> excludedPaths) {
    if (includedPaths.length != this.includedPaths.length ||
        excludedPaths.length != this.excludedPaths.length) {
      return false;
    }
    final existingIncludedSet = this.includedPaths.toSet();
    final existingExcludedSet = this.excludedPaths.toSet();

    return existingIncludedSet.containsAll(includedPaths) &&
        existingExcludedSet.containsAll(excludedPaths);
  }

  /// Starts watching for the `bazel-bin` and `blaze-bin` symlinks.
  ///
  /// This is important since these symlinks might not be present when the
  /// server starts up, in which case `BazelWorkspace` assumes by default the
  /// Bazel ones.  So we want to detect if the symlinks get created to reset
  /// everything and repeat the search for the folders.
  void _startWatchingBazelBinPaths(_BazelWatchedFiles watched) {
    var watcherService = bazelWatcherService;
    if (watcherService == null) return;
    var paths = _getPossibleBazelBinPaths(watched);
    watcherService.startWatching(
        watched.workspace, BazelSearchInfo(paths[0], paths));
  }

  /// Stops watching for the `bazel-bin` and `blaze-bin` symlinks.
  void _stopWatchingBazelBinPaths(_BazelWatchedFiles watched) {
    var watcherService = bazelWatcherService;
    if (watcherService == null) return;
    var paths = _getPossibleBazelBinPaths(watched);
    watcherService.stopWatching(watched.workspace, paths[0]);
  }

  /// Listens to files generated by Bazel that were found or searched for.
  ///
  /// This is handled specially because the files are outside the package
  /// folder, but we still want to watch for changes to them.
  ///
  /// Does nothing if the [driver] is not in a Bazel workspace.
  void _watchBazelFilesIfNeeded(Folder folder, AnalysisDriver analysisDriver) {
    if (!experimentalEnableBazelWatching) return;
    var watcherService = bazelWatcherService;
    if (watcherService == null) return;

    var workspace = analysisDriver.analysisContext?.contextRoot.workspace;
    if (workspace is BazelWorkspace &&
        !bazelSearchSubscriptions.containsKey(folder)) {
      bazelSearchSubscriptions[folder] = workspace.bazelCandidateFiles.listen(
          (notification) =>
              _handleBazelSearchInfo(folder, workspace.root, notification));

      var watched = _BazelWatchedFiles(workspace.root);
      bazelWatchedPathsPerFolder[folder] = watched;
      _startWatchingBazelBinPaths(watched);
    }
  }
}

class NoopContextManagerCallbacks implements ContextManagerCallbacks {
  @override
  void afterContextsCreated() {}

  @override
  void afterContextsDestroyed() {}

  @override
  void afterWatchEvent(WatchEvent event) {}

  @override
  void applyFileRemoved(String file) {}

  @override
  void broadcastWatchEvent(WatchEvent event) {}

  @override
  void listenAnalysisDriver(AnalysisDriver driver) {}

  @override
  void pubspecChanged(String pubspecPath) {}

  @override
  void pubspecRemoved(String pubspecPath) {}

  @override
  void recordAnalysisErrors(String path, List<protocol.AnalysisError> errors) {}
}

class _BazelWatchedFiles {
  final String workspace;
  final paths = <String>{};
  _BazelWatchedFiles(this.workspace);
}

/// Handles a task queue of tasks that cannot run concurrently.
///
/// Queueing a new task will signal for any in-progress task to cancel and
/// wait for it to complete before starting the new task.
class _CancellingTaskQueue {
  /// A cancellation token for current/last queued task.
  ///
  /// This token is replaced atomically with [_complete] and
  /// together they allow cancelling a task and chaining a new task on
  /// to the end.
  CancelableToken? _cancellationToken;

  /// A [Future] that completes when the current/last queued task finishes.
  ///
  /// This future is replaced atomically with [_cancellationToken] and together
  /// they allow cancelling a task and chaining a new task on to the end.
  Future<void> _complete = Future.value();

  /// Requests that [performTask] is called after first cancelling any
  /// in-progress task and waiting for it to complete.
  ///
  /// Returns a future that completes once the new task has completed.
  Future<void> queue(
    Future<void> Function(CancellationToken cancellationToken) performTask,
  ) {
    // Signal for any in-progress task to cancel.
    _cancellationToken?.cancel();

    // Chain the new task onto the end of any existing one, so the new
    // task never starts until the previous (cancelled) one finishes (which
    // may be by aborting early because of the cancellation signal).
    final token = _cancellationToken = CancelableToken();
    _complete = _complete
        .then((_) => performTask(token))
        .then((_) => _clearTokenIfCurrent(token));

    return _complete;
  }

  /// Clears the current cancellation token if it is [token].
  void _clearTokenIfCurrent(CancelableToken token) {
    if (token == _cancellationToken) {
      _cancellationToken = null;
    }
  }
}
