package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;

public class DataRow extends BackendMessage {
  private final ByteBuffer[] values;
  private final int length;

  public DataRow(ByteBuffer[] values, int length) {
    this.values = values;
    this.length = length;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.DataRow;
  }

  public ByteBuffer[] getValues() {
    return values;
  }
}
