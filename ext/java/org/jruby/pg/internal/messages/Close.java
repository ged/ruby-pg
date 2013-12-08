package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

public class Close extends ProtocolMessage {
  private final String name;
  private final StatementType type;
  private final byte[] bytes;

  public static enum StatementType {
    Portal,
    Prepared;
  }

  public Close(String name, StatementType type) {
    this.name = name;
    this.type = type;

    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write(getFirstByte());
      ByteUtils.writeInt4(out, 0);
      switch(type) {
      case Portal:
        out.write('P');
        break;
      case Prepared:
        out.write('S');
        break;
      }
      ByteUtils.writeString(out, name);
    } catch (Exception e) {
      // we cannot be here
    }
    this.bytes = out.toByteArray();
    ByteUtils.fixLength(bytes);
  }

  @Override
  public int getLength() {
    return bytes.length - 1;
  }

  @Override
  public MessageType getType() {
    return MessageType.Close;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }

  public String getName() {
    return name;
  }

  public StatementType getStatmentType() {
    return type;
  }
}
