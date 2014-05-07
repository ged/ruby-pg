package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.PostgresqlString;
import org.jruby.pg.internal.Value;

public class Bind extends ProtocolMessage {
  private final byte[] bytes;
  private final int length;

  public Bind(PostgresqlString destinationPortal, PostgresqlString sourceStatement, Value[] params, Format format) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('B');
      out.write(new byte[4]);
      ByteUtils.writeString(out, destinationPortal);
      ByteUtils.writeString(out, sourceStatement);
      ByteUtils.writeInt2(out, params.length);
      for (Value parameter : params) {
        ByteUtils.writeInt2(out, parameter.getFormat().getValue());
      }
      ByteUtils.writeInt2(out, params.length);
      for (Value parameter : params) {
        if (parameter.getBytes() == null) {
          ByteUtils.writeInt4(out, -1);
        } else {
          ByteUtils.writeInt4(out, parameter.getBytes().length);
          out.write(parameter.getBytes());
        }
      }
      ByteUtils.writeInt2(out, 1);
      ByteUtils.writeInt2(out, format.getValue());
    } catch (Exception ex) {
      // we cannot be here
    }

    byte[] bytes = out.toByteArray();
    ByteUtils.fixLength(bytes);
    this.bytes = bytes;
    this.length = bytes.length - 1;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.Bind;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }
}
