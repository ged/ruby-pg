package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;

public class Terminate extends ProtocolMessage {
  private final byte[] bytes = {'X', 0, 0, 0, 4};

  @Override
  public int getLength() {
    return bytes.length - 1;
  }

  @Override
  public MessageType getType() {
    return MessageType.Terminate;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
