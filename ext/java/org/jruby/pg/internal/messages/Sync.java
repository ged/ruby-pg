package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;


public class Sync extends ProtocolMessage {
  private final byte[] bytes = {'S', 0, 0, 0, 4};

  @Override
  public int getLength() {
    return 4;
  }

  @Override
  public MessageType getType() {
    return MessageType.Sync;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
