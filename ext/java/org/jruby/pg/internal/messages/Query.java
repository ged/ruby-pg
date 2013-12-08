package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.PostgresqlString;

public class Query extends ProtocolMessage {
  private final PostgresqlString query;
  private final byte[] bytes;

  public Query(PostgresqlString query) {
    this.query = query;

    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('Q');
      ByteUtils.writeInt4(out, 0);
      ByteUtils.writeString(out, query);
    } catch (Exception e) {
      // we cannot be here
    }
    bytes = out.toByteArray();
    ByteUtils.fixLength(bytes);
  }

  @Override
  public int getLength() {
    return bytes.length - 1;
  }

  @Override
  public MessageType getType() {
    return MessageType.Query;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }

  public PostgresqlString getQuery() {
    return query;
  }
}
