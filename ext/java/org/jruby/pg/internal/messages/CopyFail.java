package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

public class CopyFail extends ProtocolMessage {
  private final byte[] bytes;

  public CopyFail(String error) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('f');
      ByteUtils.writeInt4(out, 0);
      ByteUtils.writeString(out, error);
    } catch (Exception e) {
      // we cannot be here
    }
    this.bytes =  out.toByteArray();
  }

  @Override
  public int getLength() {
    return bytes.length - 1;
  }

  @Override
  public MessageType getType() {
    return MessageType.CopyFail;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
