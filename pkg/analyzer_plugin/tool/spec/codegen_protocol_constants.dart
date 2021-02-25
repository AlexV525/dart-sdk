// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer_utilities/tools.dart';

import 'api.dart';
import 'codegen_dart.dart';
import 'from_html.dart';

final GeneratedFile target = GeneratedFile(
    'lib/protocol/protocol_constants.dart', (String pkgPath) async {
  var visitor = CodegenVisitor(readApi(pkgPath));
  return visitor.collectCode(visitor.visitApi);
});

/// A visitor that produces Dart code defining constants associated with the
/// API.
class CodegenVisitor extends DartCodegenVisitor with CodeGenerator {
  CodegenVisitor(Api api) : super(api) {
    codeGeneratorSettings.commentLineLength = 79;
    codeGeneratorSettings.docCommentStartMarker = null;
    codeGeneratorSettings.docCommentLineLeader = '/// ';
    codeGeneratorSettings.docCommentEndMarker = null;
    codeGeneratorSettings.languageName = 'dart';
  }

  /// Generate all of the constants associates with the [api].
  void generateConstants() {
    var visitor = _ConstantVisitor(api);
    visitor.visitApi();
    var constants = visitor.constants;
    constants.sort((first, second) => first.name.compareTo(second.name));
    for (var constant in constants) {
      generateContant(constant);
    }
  }

  /// Generate the given [constant].
  void generateContant(_Constant constant) {
    write('const String ');
    write(constant.name);
    write(' = ');
    write(constant.value);
    writeln(';');
  }

  @override
  void visitApi() {
    outputHeader(year: '2017');
    writeln();
    generateConstants();
  }
}

/// A representation of a constant that is to be generated.
class _Constant {
  /// The name of the constant.
  final String name;

  /// The value of the constant.
  final String value;

  /// Initialize a newly created constant.
  _Constant(this.name, this.value);
}

/// A visitor that visits an API to compute a list of constants to be generated.
class _ConstantVisitor extends HierarchicalApiVisitor {
  /// The list of constants to be generated.
  List<_Constant> constants = <_Constant>[];

  /// Initialize a newly created visitor to visit the given [api].
  _ConstantVisitor(Api api) : super(api);

  @override
  void visitNotification(Notification notification) {
    var domainName = notification.domainName;
    var event = notification.event;

    var constantName = _generateName(domainName, 'notification', event);
    constants.add(_Constant(constantName, "'$domainName.$event'"));
    _addFieldConstants(constantName, notification.params);
  }

  @override
  void visitRequest(Request request) {
    var domainName = request.domainName;
    var method = request.method;

    var requestConstantName = _generateName(domainName, 'request', method);
    constants.add(_Constant(requestConstantName, "'$domainName.$method'"));
    _addFieldConstants(requestConstantName, request.params);

    var responseConstantName = _generateName(domainName, 'response', method);
    _addFieldConstants(responseConstantName, request.result);
  }

  /// Generate a constant for each of the fields in the given [type], where the
  /// name of each constant will be composed from the [parentName] and the name
  /// of the field.
  void _addFieldConstants(String parentName, TypeObject type) {
    if (type == null) {
      return;
    }
    type.fields.forEach((TypeObjectField field) {
      var name = field.name;
      var components = <String>[];
      components.add(parentName);
      components.addAll(_split(name));
      var fieldConstantName = _fromComponents(components);
      constants.add(_Constant(fieldConstantName, "'$name'"));
    });
  }

  /// Return a name generated by converting each of the given [components] to an
  /// uppercase equivalent, then joining them with underscores.
  String _fromComponents(List<String> components) =>
      components.map((String component) => component.toUpperCase()).join('_');

  /// Generate a name from the [domainName], [kind] and [name] components.
  String _generateName(String domainName, String kind, String name) {
    var components = <String>[];
    components.addAll(_split(domainName));
    components.add(kind);
    components.addAll(_split(name));
    return _fromComponents(components);
  }

  /// Return the components of the given [string] that are indicated by an upper
  /// case letter.
  Iterable<String> _split(String first) {
    var regExp = RegExp('[A-Z]');
    var components = <String>[];
    var start = 1;
    var index = first.indexOf(regExp, start);
    while (index >= 0) {
      components.add(first.substring(start - 1, index));
      start = index + 1;
      index = first.indexOf(regExp, start);
    }
    components.add(first.substring(start - 1));
    return components;
  }
}
