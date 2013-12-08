package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.PostgresqlString;
import org.jruby.pg.internal.messages.Close.StatementType;

public class Describe extends ProtocolMessage {
  private final PostgresqlString name;
  private final StatementType statementType;
  private final byte[] bytes;

  public Describe(PostgresqlString name, StatementType statementType) {
    this.name = name;
    this.statementType = statementType;

    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write('D');
      ByteUtils.writeInt4(out, 0);
      switch (statementType) {
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
    return MessageType.Describe;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }

  public PostgresqlString getName() {
    return name;
  }

  public StatementType getStatementType() {
    return statementType;
  }
}
