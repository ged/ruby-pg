package org.jruby.pg.internal.messages;

public class ParseComplete extends BackendMessage {

  @Override
  public int getLength() {
    return -1;
  }

  @Override
  public MessageType getType() {
    return MessageType.ParseComplete;
  }
}
