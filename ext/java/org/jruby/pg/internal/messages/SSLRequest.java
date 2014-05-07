package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

public class SSLRequest extends ProtocolMessage {
  private final byte[] bytes;

  public SSLRequest() {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      ByteUtils.writeInt4(out, 8);
      ByteUtils.writeInt4(out, 80877103);
    } catch (Exception e) {
      // we cannot be here
    }
    bytes = out.toByteArray();
  }

  @Override
  public int getLength() {
    return -1;
  }

  @Override
  public MessageType getType() {
    return MessageType.SSLRequest;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
