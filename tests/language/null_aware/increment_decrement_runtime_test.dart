// TODO(multitest): This was automatically migrated from a multitest and may
// contain strange or dead code.

// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Verify semantics of the ?. operator when it appears in a postincrement or
// preincrement expression (or a postdecrement or predecrement expression).

import "package:expect/expect.dart";
import "conditional_access_helper.dart" as h;

class C {
  int v;
  C(this.v);
  static late int staticInt;
}

class D {
  E v;
  D(this.v);
  static late E staticE;
}

class E {
  G operator +(int i) => new I();
  G operator -(int i) => new I();
}

class F {}

class G extends E implements F {}

class H {}

class I extends G implements H {}

C? nullC() => null;

main() {
  // Make sure the "none" test fails if assignment to "?." is not implemented.
  // This makes status files easier to maintain.
  nullC()?.v = 1;

  // e1?.v++ is equivalent to ((x) => x == null ? null : x.v++)(e1).
  Expect.equals(null, nullC()?.v++);
  {
    C? c = new C(1) as dynamic;
    Expect.equals(1, c?.v++);
    Expect.equals(2, c!.v);
  }

  // C?.v++ is equivalent to C.v++.
  {
    C.staticInt = 1;
    Expect.equals(1, C?.staticInt++);
    //                ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(2, C.staticInt);
  }
  {
    h.C.staticInt = 1;
    Expect.equals(1, h.C?.staticInt++);
    //                  ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(2, h.C.staticInt);
  }

  // The static type of e1?.v++ is the same as the static type of e1.v.
  {
    E e1 = new E();
    D? d = new D(e1) as dynamic;
    E? e2 = d?.v++;
    Expect.identical(e1, e2);
  }

  {
    E e1 = new E();
    D.staticE = e1;
    E? e2 = D?.staticE++;
    //       ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(e1, e2);
  }
  {
    h.E e1 = new h.E();
    h.D.staticE = e1;
    h.E? e2 = h.D?.staticE++;
    //           ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(e1, e2);
  }

  // e1?.v-- is equivalent to ((x) => x == null ? null : x.v--)(e1).
  Expect.equals(null, nullC()?.v--);
  {
    C? c = new C(1) as dynamic;
    Expect.equals(1, c?.v--);
    Expect.equals(0, c!.v);
  }

  // C?.v-- is equivalent to C.v--.
  {
    C.staticInt = 1;
    Expect.equals(1, C?.staticInt--);
    //                ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(0, C.staticInt);
  }
  {
    h.C.staticInt = 1;
    Expect.equals(1, h.C?.staticInt--);
    //                  ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(0, h.C.staticInt);
  }

  // The static type of e1?.v-- is the same as the static type of e1.v.
  {
    E e1 = new E();
    D? d = new D(e1) as dynamic;
    E? e2 = d?.v--;
    Expect.identical(e1, e2);
  }

  {
    E e1 = new E();
    D.staticE = e1;
    E? e2 = D?.staticE--;
    //       ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(e1, e2);
  }
  {
    h.E e1 = new h.E();
    h.D.staticE = e1;
    h.E? e2 = h.D?.staticE--;
    //           ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(e1, e2);
  }

  // ++e1?.v is equivalent to e1?.v += 1.
  Expect.equals(null, ++nullC()?.v);
  {
    C? c = new C(1) as dynamic;
    Expect.equals(2, ++c?.v);
    Expect.equals(2, c!.v);
  }

  // ++C?.v is equivalent to C?.v += 1.
  {
    C.staticInt = 1;
    Expect.equals(2, ++C?.staticInt);
    //                  ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(2, C.staticInt);
  }
  {
    h.C.staticInt = 1;
    Expect.equals(2, ++h.C?.staticInt);
    //                    ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(2, h.C.staticInt);
  }

  // The static type of ++e1?.v is the same as the static type of e1.v + 1.
  {
    D? d = new D(new E()) as dynamic;
    F? f = ++d?.v;
    Expect.identical(d!.v, f);
  }

  {
    D? d = new D(new E()) as dynamic;
    F? f = ++d?.v;
    Expect.identical(d!.v, f);
  }
  {
    h.D.staticE = new h.E();
    h.F? f = ++h.D?.staticE;
    //            ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(h.D.staticE, f);
  }

  // --e1?.v is equivalent to e1?.v -= 1.
  Expect.equals(null, --nullC()?.v);
  {
    C? c = new C(1) as dynamic;
    Expect.equals(0, --c?.v);
    Expect.equals(0, c!.v);
  }

  // --C?.v is equivalent to C?.v -= 1.
  {
    C.staticInt = 1;
    Expect.equals(0, --C?.staticInt);
    //                  ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(0, C.staticInt);
  }
  {
    h.C.staticInt = 1;
    Expect.equals(0, --h.C?.staticInt);
    //                    ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.equals(0, h.C.staticInt);
  }

  // The static type of --e1?.v is the same as the static type of e1.v - 1.
  {
    D? d = new D(new E()) as dynamic;
    F? f = --d?.v;
    Expect.identical(d!.v, f);
  }

  {
    D.staticE = new E();
    F? f = --D?.staticE;
    //        ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(D.staticE, f);
  }

  {
    h.D.staticE = new h.E();
    h.F? f = --h.D?.staticE;
    //            ^^
    // [analyzer] STATIC_WARNING.INVALID_NULL_AWARE_OPERATOR
    Expect.identical(h.D.staticE, f);
  }
}
