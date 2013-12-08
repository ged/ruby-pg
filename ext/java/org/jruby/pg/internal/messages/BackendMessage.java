package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;

public abstract class BackendMessage extends ProtocolMessage {
  @Override
  public ByteBuffer toBytes() {
    throw new UnsupportedOperationException("Backend messages shouldn't be converted to bytes");
  }
}
