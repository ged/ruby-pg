package org.jruby.pg.internal;

import java.nio.ByteBuffer;

import org.jruby.pg.internal.messages.ProtocolMessage;

public class Flush extends ProtocolMessage {
  private final byte [] bytes = {'H', 0, 0, 0, 4};

  @Override
  public int getLength() {
    return -1;
  }

  @Override
  public MessageType getType() {
    return MessageType.Flush;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
