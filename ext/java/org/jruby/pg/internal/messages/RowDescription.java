package org.jruby.pg.internal.messages;

public class RowDescription extends BackendMessage {
  private final Column[] columns;
  private final int length;

  public RowDescription(Column[] columns, int length) {
    this.columns = columns;
    this.length = length;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.RowDescription;
  }

  public Column[] getColumns() {
    return columns;
  }
}
