package org.jruby.pg.internal;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.messages.ByteUtils;
import org.jruby.pg.internal.messages.ProtocolMessage;

public class Execute extends ProtocolMessage {
  private final byte[] bytes;
  private final int length;

  public Execute(PostgresqlString name) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('E');
      ByteUtils.writeInt4(out, 0);
      ByteUtils.writeString(out, name);
      ByteUtils.writeInt4(out, 0);
    } catch (Exception e) {
      // we cannot be here
    }
    bytes = out.toByteArray();
    ByteUtils.fixLength(bytes);
    length = bytes.length;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.Execute;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
