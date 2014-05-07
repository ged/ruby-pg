package org.jruby.pg;

import java.util.List;
import java.util.Map;

public class PgPreparedStatement {
  public final Map<Integer, List<Integer> > indexMapping;
  public final java.sql.PreparedStatement st;

  public PgPreparedStatement(java.sql.PreparedStatement st, Map<Integer, List<Integer>> indexMapping) {
    this.st = st;
    this.indexMapping = indexMapping;
  }
}
