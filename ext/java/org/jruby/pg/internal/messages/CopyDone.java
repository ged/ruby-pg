package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;

public class CopyDone extends ProtocolMessage {
  private final static byte[] bytes = {'c', 0, 0, 0, 4};

  @Override
  public int getLength() {
    return 4;
  }

  @Override
  public MessageType getType() {
    return MessageType.CopyDone;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
