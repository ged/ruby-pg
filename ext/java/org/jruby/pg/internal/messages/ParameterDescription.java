package org.jruby.pg.internal.messages;

public class ParameterDescription extends BackendMessage {
  private final int[] oids;
  private final int length;

  public ParameterDescription(int [] oids, int length) {
    this.oids = oids;
    this.length = length;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.ParameterDescription;
  }

  public int[] getOids() {
    return oids;
  }
}
