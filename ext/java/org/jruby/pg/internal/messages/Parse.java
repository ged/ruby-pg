package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.PostgresqlString;

public class Parse extends ProtocolMessage {

  private final byte[] bytes;
  private final int length;

  public Parse(PostgresqlString name, PostgresqlString query, int [] oids) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('P');
      ByteUtils.writeInt4(out, 0);
      ByteUtils.writeString(out, name);
      ByteUtils.writeString(out, query);
      ByteUtils.writeInt2(out, oids.length);
      for (int oid : oids)
        ByteUtils.writeInt4(out, oid);
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
    return MessageType.Parse;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
