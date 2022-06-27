// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/library_context.dart';
import 'package:analyzer/src/dart/analysis/library_graph.dart';
import 'package:analyzer/src/dart/micro/resolve_file.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

class AnalyzerStatePrinter {
  final MemoryByteStore byteStore;
  final IdProvider idProvider;
  final LibraryContext libraryContext;
  final bool omitSdkFiles;
  final ResourceProvider resourceProvider;
  final StringSink sink;
  final bool withKeysGetPut;

  String _indent = '';

  AnalyzerStatePrinter({
    required this.byteStore,
    required this.idProvider,
    required this.libraryContext,
    required this.omitSdkFiles,
    required this.resourceProvider,
    required this.sink,
    required this.withKeysGetPut,
  });

  FileSystemState get fileSystemState => libraryContext.fileSystemState;

  void writeAnalysisDriver(AnalysisDriverTestView testData) {
    _writeFiles(testData.fileSystem);
    _writeLibraryContext(testData.libraryContext);
    _writeElementFactory();
  }

  void writeFileResolver(FileResolverTestData testData) {
    _writeFiles(testData.fileSystem);
    _writeLibraryContext(testData.libraryContext);
    _writeElementFactory();
    _writeByteStore();
  }

  /// If the path style is `Windows`, returns the corresponding Posix path.
  /// Otherwise the path is already a Posix path, and it is returned as is.
  String _posixPath(File file) {
    final pathContext = resourceProvider.pathContext;
    if (pathContext.style == Style.windows) {
      final components = pathContext.split(file.path);
      return '/${components.skip(1).join('/')}';
    } else {
      return file.path;
    }
  }

  String _stringOfLibraryCycle(LibraryCycle cycle) {
    if (omitSdkFiles) {
      final isSdkLibrary = cycle.libraries.any((file) {
        return file.uri.isScheme('dart');
      });
      if (isSdkLibrary) {
        if (cycle.libraries.any((e) => e.uriStr == 'dart:core')) {
          return 'dart:core';
        } else {
          throw UnimplementedError('$cycle');
        }
      }
    }
    return idProvider.libraryCycle(cycle);
  }

  void _withIndent(void Function() f) {
    var indent = _indent;
    _indent = '$_indent  ';
    f();
    _indent = indent;
  }

  /// TODO(scheglov) Support unresolved URIs, not augmentations, etc.
  void _writeAugmentations(LibraryOrAugmentationFileKind kind) {
    final files = kind.file.augmentationFiles.whereNotNull();
    if (files.isNotEmpty) {
      final keys = files.map(idProvider.fileState).join(' ');
      _writelnWithIndent('augmentations: $keys');
    }
  }

  void _writeByteStore() {
    _writelnWithIndent('byteStore');
    _withIndent(() {
      final groups = byteStore.map.entries.groupListsBy((element) {
        return element.value.refCount;
      });

      for (final groupEntry in groups.entries) {
        final keys = groupEntry.value.map((e) => e.key).toList();
        final shortKeys = idProvider.shortKeys(keys)..sort();
        _writelnWithIndent('${groupEntry.key}: $shortKeys');
      }
    });
  }

  void _writeElementFactory() {
    _writelnWithIndent('elementFactory');
    _withIndent(() {
      final elementFactory = libraryContext.elementFactory;
      _writeUriList(
        'hasElement',
        elementFactory.uriListWithLibraryElements,
      );
      _writeUriList(
        'hasReader',
        elementFactory.uriListWithLibraryReaders,
      );
    });
  }

  void _writeElements<T>(String name, List<T> elements, void Function(T) f) {
    if (elements.isNotEmpty) {
      _writelnWithIndent(name);
      _withIndent(() {
        for (var element in elements) {
          f(element);
        }
      });
    }
  }

  void _writeFile(FileState file) {
    _withIndent(() {
      _writelnWithIndent('id: ${idProvider.fileState(file)}');
      _writeFileKind(file);
      _writeReferencingFiles(file);
      _writeFileUnlinkedKey(file);
    });
  }

  void _writeFileExports(LibraryOrAugmentationFileKind file) {
    _writeElements<ExportDirectiveState>('exports', file.exports, (export) {
      if (export is ExportDirectiveWithFile) {
        final file = export.exportedFile;
        sink.write(_indent);

        final exportedLibrary = export.exportedLibrary;
        if (exportedLibrary != null) {
          expect(exportedLibrary.file, file);
          sink.write(idProvider.fileStateKind(exportedLibrary));
        } else {
          sink.write('notLibrary ${idProvider.fileState(file)}');
        }

        if (omitSdkFiles && file.uri.isScheme('dart')) {
          sink.write(' ${file.uri}');
        }
        sink.writeln();
      } else if (export is ExportDirectiveWithInSummarySource) {
        sink.write(_indent);
        sink.write('inSummary ${export.exportedSource.uri}');

        final librarySource = export.exportedLibrarySource;
        if (librarySource != null) {
          expect(librarySource, same(export.exportedSource));
        } else {
          sink.write(' notLibrary');
        }
        sink.writeln();
      } else {
        sink.write(_indent);
        sink.write('uri: ${export.directive.uri}');
        sink.writeln();
      }
    });
  }

  void _writeFileImports(LibraryOrAugmentationFileKind file) {
    _writeElements<ImportDirectiveState>('imports', file.imports, (import) {
      if (import is ImportDirectiveWithFile) {
        final file = import.importedFile;
        sink.write(_indent);

        final importedLibrary = import.importedLibrary;
        if (importedLibrary != null) {
          expect(importedLibrary.file, file);
          sink.write(idProvider.fileStateKind(importedLibrary));
        } else {
          sink.write('notLibrary ${idProvider.fileState(file)}');
        }

        if (omitSdkFiles && file.uri.isScheme('dart')) {
          sink.write(' ${file.uri}');
        }

        if (import.isSyntheticDartCoreImport) {
          sink.write(' synthetic');
        }
        sink.writeln();
      } else if (import is ImportDirectiveWithInSummarySource) {
        sink.write(_indent);
        sink.write('inSummary ${import.importedSource.uri}');

        final librarySource = import.importedLibrarySource;
        if (librarySource != null) {
          expect(librarySource, same(import.importedSource));
        } else {
          sink.write(' notLibrary');
        }

        if (import.isSyntheticDartCoreImport) {
          sink.write(' synthetic');
        }
        sink.writeln();
      } else {
        sink.write(_indent);
        sink.write('uri: ${import.directive.uri}');
        if (import.isSyntheticDartCoreImport) {
          sink.write(' synthetic');
        }
        sink.writeln();
      }
    });
  }

  void _writeFileKind(FileState file) {
    final kind = file.kind;
    expect(kind.file, same(file));

    _writelnWithIndent('kind: ${idProvider.fileStateKind(kind)}');
    if (kind is AugmentationKnownFileStateKind) {
      _withIndent(() {
        final augmented = kind.augmented;
        if (augmented != null) {
          final id = idProvider.fileStateKind(augmented);
          _writelnWithIndent('augmented: $id');
        } else {
          final id = idProvider.fileState(kind.uriFile);
          _writelnWithIndent('uriFile: $id');
        }

        final library = kind.library;
        if (library != null) {
          final id = idProvider.fileStateKind(library);
          _writelnWithIndent('library: $id');
        }

        _writeFileImports(kind);
        _writeFileExports(kind);
        _writeAugmentations(kind);
      });
    } else if (kind is AugmentationUnknownFileStateKind) {
      _withIndent(() {
        _writelnWithIndent('uri: ${kind.directive.uri}');
      });
    } else if (kind is LibraryFileStateKind) {
      expect(kind.library, same(kind));

      _withIndent(() {
        final name = kind.name;
        if (name != null) {
          _writelnWithIndent('name: $name');
        }

        _writeFileImports(kind);
        _writeFileExports(kind);
        _writeLibraryParts(kind);
        _writeAugmentations(kind);
        _writeLibraryCycle(kind);
      });
    } else if (kind is PartOfNameFileStateKind) {
      _withIndent(() {
        final libraries = kind.libraries;
        if (libraries.isNotEmpty) {
          final keys = libraries
              .map(idProvider.fileStateKind)
              .sorted(compareNatural)
              .join(' ');
          _writelnWithIndent('libraries: $keys');
        }

        final library = kind.library;
        if (library != null) {
          final id = idProvider.fileStateKind(library);
          _writelnWithIndent('library: $id');
        } else {
          _writelnWithIndent('name: ${kind.directive.name}');
        }
      });
    } else if (kind is PartOfUriKnownFileStateKind) {
      _withIndent(() {
        final library = kind.library;
        if (library != null) {
          final id = idProvider.fileStateKind(library);
          _writelnWithIndent('library: $id');
        } else {
          final id = idProvider.fileState(kind.uriFile);
          _writelnWithIndent('uriFile: $id');
        }
      });
    } else if (kind is PartOfUriUnknownFileStateKind) {
      _withIndent(() {
        _writelnWithIndent('uri: ${kind.directive.uri}');
        expect(kind.library, isNull);
      });
    } else {
      throw UnimplementedError('${kind.runtimeType}');
    }
  }

  void _writeFiles(FileSystemTestData testData) {
    fileSystemState.pullReferencedFiles();

    final fileDataList = <FileTestData>[];
    for (final fileData in testData.files.values) {
      if (omitSdkFiles && fileData.uri.isScheme('dart')) {
        continue;
      }
      fileDataList.add(fileData);
    }
    fileDataList.sortBy((fileData) => fileData.file.path);

    // Ask ID for every file in the sorted order, so that IDs are nice.
    for (final fileData in fileDataList) {
      final current = fileSystemState.getExisting(fileData.file);
      if (current != null) {
        idProvider.fileState(current);
        final kind = current.kind;
        idProvider.fileStateKind(kind);
        if (kind is LibraryFileStateKind) {
          idProvider.libraryCycle(kind.libraryCycle);
        }
      }
    }

    _writelnWithIndent('files');
    _withIndent(() {
      for (final fileData in fileDataList) {
        final file = fileData.file;
        _writelnWithIndent(_posixPath(file));
        _withIndent(() {
          _writelnWithIndent('uri: ${fileData.uri}');

          final current = fileSystemState.getExisting(file);
          if (current != null) {
            _writelnWithIndent('current');
            _writeFile(current);
          }

          if (withKeysGetPut) {
            final shortGets = idProvider.shortKeys(fileData.unlinkedKeyGet);
            final shortPuts = idProvider.shortKeys(fileData.unlinkedKeyPut);
            _writelnWithIndent('unlinkedGet: $shortGets');
            _writelnWithIndent('unlinkedPut: $shortPuts');
          }
        });
      }
    });
  }

  void _writeFileUnlinkedKey(FileState file) {
    final unlinkedShort = idProvider.shortKey(file.unlinkedKey);
    _writelnWithIndent('unlinkedKey: $unlinkedShort');
  }

  void _writeLibraryContext(LibraryContextTestData testData) {
    _writelnWithIndent('libraryCycles');
    _withIndent(() {
      final cyclesToPrint = <_LibraryCycleToPrint>[];
      for (final entry in testData.libraryCycles.entries) {
        if (omitSdkFiles && entry.key.any((e) => e.uri.isScheme('dart'))) {
          continue;
        }
        cyclesToPrint.add(
          _LibraryCycleToPrint(
            entry.key.map((e) => _posixPath(e.file)).join(' '),
            entry.value,
          ),
        );
      }
      cyclesToPrint.sortBy((e) => e.pathListStr);

      final loadedBundlesMap = Map.fromEntries(
        libraryContext.loadedBundles.map((cycle) {
          final key = cycle.libraries
              .map((fileState) => fileState.resource)
              .map(_posixPath)
              .join(' ');
          return MapEntry(key, cycle);
        }),
      );

      for (final cycleToPrint in cyclesToPrint) {
        _writelnWithIndent(cycleToPrint.pathListStr);
        _withIndent(() {
          final current = loadedBundlesMap[cycleToPrint.pathListStr];
          if (current != null) {
            _writelnWithIndent('current');
            _withIndent(() {
              final short = idProvider.shortKey(current.resolutionKey!);
              _writelnWithIndent('key: $short');

              final fileIdList = current.libraries
                  .map(idProvider.fileState)
                  .sorted(compareNatural)
                  .toList();
              _writelnWithIndent('libraries: ${fileIdList.join(' ')}');
            });
          }

          final cycleData = cycleToPrint.data;
          final shortGets = idProvider.shortKeys(cycleData.getKeys);
          final shortPuts = idProvider.shortKeys(cycleData.putKeys);
          _writelnWithIndent('get: $shortGets');
          _writelnWithIndent('put: $shortPuts');
        });
      }
    });
  }

  void _writeLibraryCycle(LibraryFileStateKind library) {
    final cycle = library.libraryCycle;
    _writelnWithIndent(idProvider.libraryCycle(cycle));
    _withIndent(() {
      final dependencyIds = cycle.directDependencies
          .map(_stringOfLibraryCycle)
          .sorted(compareNatural)
          .join(' ');
      if (dependencyIds.isNotEmpty) {
        _writelnWithIndent('dependencies: $dependencyIds');
      } else {
        _writelnWithIndent('dependencies: none');
      }

      // TODO(scheglov) libraries must be kinds
      final libraryIds = cycle.libraries
          .map((e) => e.kind as LibraryFileStateKind)
          .map(idProvider.fileStateKind)
          .sorted(compareNatural)
          .join(' ');
      _writelnWithIndent('libraries: $libraryIds');

      _writelnWithIndent(idProvider.apiSignature(cycle.apiSignature));

      final userIds = cycle.directUsers
          .map(_stringOfLibraryCycle)
          .sorted(compareNatural)
          .join(' ');
      if (userIds.isNotEmpty) {
        _writelnWithIndent('users: $userIds');
      }
    });
  }

  /// TODO(scheglov) Support unresolved URIs, not parts, etc.
  void _writeLibraryParts(LibraryFileStateKind library) {
    final parts = library.file.partedFiles.whereNotNull();
    if (parts.isNotEmpty) {
      final partKeys = parts.map(idProvider.fileState).join(' ');
      _writelnWithIndent('parts: $partKeys');
    }
  }

  void _writelnWithIndent(String line) {
    sink.write(_indent);
    sink.writeln(line);
  }

  void _writeReferencingFiles(FileState file) {
    final referencingFiles = file.referencingFiles;
    if (referencingFiles.isNotEmpty) {
      // TODO(scheglov) Print space-separated.
      final fileIds =
          referencingFiles.map(idProvider.fileState).sorted(compareNatural);
      _writelnWithIndent('referencingFiles: $fileIds');
    }
  }

  void _writeUriList(String name, Iterable<Uri> uriIterable) {
    final uriStrList = <String>[];
    for (final uri in uriIterable) {
      if (omitSdkFiles && uri.isScheme('dart')) {
        continue;
      }
      uriStrList.add('$uri');
    }

    if (uriStrList.isNotEmpty) {
      uriStrList.sort();
      _writelnWithIndent(name);
      _withIndent(() {
        for (final uriStr in uriStrList) {
          _writelnWithIndent(uriStr);
        }
      });
    }
  }
}

/// Encoder of object identifies into short identifiers.
class IdProvider {
  final Map<FileState, String> _fileState = Map.identity();
  final Map<LibraryCycle, String> _libraryCycle = Map.identity();
  final Map<FileStateKind, String> _fileStateKind = Map.identity();
  final Map<String, String> _keyToShort = {};
  final Map<String, String> _shortToKey = {};
  final Map<String, String> _apiSignature = {};

  String apiSignature(String signature) {
    final length = _apiSignature.length;
    return _apiSignature[signature] ??= 'apiSignature_$length';
  }

  String fileState(FileState file) {
    return _fileState[file] ??= 'file_${_fileState.length}';
  }

  String fileStateKind(FileStateKind kind) {
    return _fileStateKind[kind] ??= () {
      if (kind is AugmentationKnownFileStateKind) {
        return 'augmentation_${_fileStateKind.length}';
      } else if (kind is AugmentationUnknownFileStateKind) {
        return 'augmentationUnknown_${_fileStateKind.length}';
      } else if (kind is LibraryFileStateKind) {
        return 'library_${_fileStateKind.length}';
      } else if (kind is PartOfNameFileStateKind) {
        return 'partOfName_${_fileStateKind.length}';
      } else if (kind is PartOfUriKnownFileStateKind) {
        return 'partOfUriKnown_${_fileStateKind.length}';
      } else if (kind is PartFileStateKind) {
        return 'partOfUriUnknown_${_fileStateKind.length}';
      } else {
        throw UnimplementedError('${kind.runtimeType}');
      }
    }();
  }

  String libraryCycle(LibraryCycle cycle) {
    return _libraryCycle[cycle] ??= 'cycle_${_libraryCycle.length}';
  }

  String shortKey(String key) {
    var short = _keyToShort[key];
    if (short == null) {
      short = 'k${_keyToShort.length.toString().padLeft(2, '0')}';
      _keyToShort[key] = short;
      _shortToKey[short] = key;
    }
    return short;
  }

  List<String> shortKeys(List<String> keys) {
    return keys.map(shortKey).toList();
  }
}

class _LibraryCycleToPrint {
  final String pathListStr;
  final LibraryCycleTestData data;

  _LibraryCycleToPrint(this.pathListStr, this.data);
}
