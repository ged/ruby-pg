package org.jruby.pg.internal.messages;

public class CloseComplete extends BackendMessage {

  @Override
  public int getLength() {
    return 4;
  }

  @Override
  public MessageType getType() {
    return MessageType.CloseComplete;
  }
}
