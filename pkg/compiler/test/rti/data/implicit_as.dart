// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*spec.class: C:explicit=[C.T?,C<String>],needsArgs,test*/
class C<T> {
  T? field;
}

main() {
  implicitAs(new C<String>());
}

C<String> implicitAs(C<String> i) {
  dynamic j = i;
  return j;
}
