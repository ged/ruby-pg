package org.jruby.pg.internal.messages;

public class ParameterStatus extends BackendMessage {
  private final String name;
  private final String value;
  private final int length;

  public ParameterStatus(String name, String value) {
    this.name = name;
    this.value = value;
    this.length = name.getBytes().length + value.getBytes().length + 2 + 4;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.ParameterStatus;
  }

  public String getName() {
    return name;
  }

  public String getValue() {
    return value;
  }
}
