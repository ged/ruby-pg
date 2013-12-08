package org.jruby.pg.internal.messages;

public class Column {
  private final String name;
  private final int tableOid;
  private final int tableIndex;
  private final int oid;
  private final int size;
  private final int typmod;
  private final int format;

  public Column(String name, int tableOid, int tableIndex, int oid, int size, int typmod, int format) {
    this.name = name;
    this.tableOid = tableOid;
    this.tableIndex = tableIndex;
    this.oid = oid;
    this.size = size;
    this.typmod = typmod;
    this.format = format;
  }

  public String getName() {
    return name;
  }

  public int getTableOid() {
    return tableOid;
  }

  public int getTableIndex() {
    return tableIndex;
  }

  public int getOid() {
    return oid;
  }

  public int getSize() {
    return size;
  }

  public int getTypmod() {
    return typmod;
  }

  public int getFormat() {
    return format;
  }
}
