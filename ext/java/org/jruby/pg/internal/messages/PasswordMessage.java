package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

public class PasswordMessage extends ProtocolMessage {
  private final byte[] bytes;

  public PasswordMessage(byte[] password) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('p');
      ByteUtils.writeInt4(out, 0);
      out.write(password);
      out.write('\0');
    } catch (Exception e) {
      // we cannot be here
    }
    bytes = out.toByteArray();
    ByteUtils.fixLength(bytes);
  }

  @Override
  public int getLength() {
    return -1;
  }

  @Override
  public MessageType getType() {
    return MessageType.PasswordMessage;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
