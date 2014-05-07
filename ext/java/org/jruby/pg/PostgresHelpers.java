package org.jruby.pg;

import org.jruby.runtime.builtin.IRubyObject;

public class PostgresHelpers {
  public static String stringify(Object obj) {
    if (obj instanceof IRubyObject)
      return ((IRubyObject) obj).asJavaString();
    return obj.toString();
  }
}
