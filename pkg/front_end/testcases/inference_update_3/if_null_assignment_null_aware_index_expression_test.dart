// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Tests the functionality proposed in
// https://github.com/dart-lang/language/issues/1618#issuecomment-1507241494,
// using if-null assignments whose target is a null-aware index expression.

/// Ensures a context type of `Iterable<T>?` for the operand, or `Iterable<_>?`
/// if no type argument is supplied.
Iterable<T>? contextIterableQuestion<T>(Iterable<T>? x) => x;

class A {}

class B1<T> implements A {}

class B2<T> implements A {}

class C1<T> implements B1<T>, B2<T> {}

class C2<T> implements B1<T>, B2<T> {}

/// Ensures a context type of `B1<T>?` for the operand, or `B1<_>?` if no type
/// argument is supplied.
B1<T>? contextB1Question<T>(B1<T>? x) => x;

class Indexable<ReadType, WriteType> {
  final ReadType _value;

  Indexable(this._value);

  ReadType operator [](int index) => _value;

  operator []=(int index, WriteType value) {}
}

Indexable<ReadType, WriteType>? maybeIndexable<ReadType, WriteType>(
        ReadType value) =>
    Indexable<ReadType, WriteType>(value);

main() {
  var c2Double = C2<double>();
  contextB1Question(maybeIndexable<C1<int>?, Object?>(null)?[0] ??= c2Double);

  var listNum = <num>[];
  contextIterableQuestion<num>(
      maybeIndexable<Iterable<int>?, Object?>(null)?[0] ??= listNum);
}
