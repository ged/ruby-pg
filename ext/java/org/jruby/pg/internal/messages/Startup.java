package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

public class Startup extends ProtocolMessage {
  private final byte[] bytes;

  public Startup(String user, String database, String options) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      ByteUtils.writeInt4(out, 0);
      ByteUtils.writeInt2(out, 3);
      ByteUtils.writeInt2(out, 0);
      ByteUtils.writeString(out, "user");
      ByteUtils.writeString(out, user);
      ByteUtils.writeString(out, "database");
      ByteUtils.writeString(out, database);
      ByteUtils.writeString(out, "options");
      ByteUtils.writeString(out, options);
      out.write('\0');
    } catch (Exception e) {
      // we cannot be here
    }
    this.bytes = out.toByteArray();
    ByteUtils.fixLength(bytes, 0);
  }

  @Override
  public int getLength() {
    return bytes.length;
  }

  @Override
  public MessageType getType() {
    return MessageType.StartupMessage;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
