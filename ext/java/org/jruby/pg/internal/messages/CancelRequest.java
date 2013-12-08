package org.jruby.pg.internal.messages;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

public class CancelRequest extends ProtocolMessage {
  private final int pid;
  private final int secret;
  private final byte[] bytes;

  public CancelRequest(int pid, int secret) {
    this.pid = pid;
    this.secret = secret;

    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      ByteUtils.writeInt4(out, getLength());
      ByteUtils.writeInt4(out, 80877102);
      ByteUtils.writeInt4(out, pid);
      ByteUtils.writeInt4(out, secret);
    } catch (Exception e) {
      // we cannot be here
    }
    this.bytes = out.toByteArray();
  }

  @Override
  public int getLength() {
    return 16;
  }

  @Override
  public MessageType getType() {
    return MessageType.CancelRequest;
  }

  @Override
  public ByteBuffer toBytes() {
    return ByteBuffer.wrap(bytes);
  }

  public int getPid() {
    return pid;
  }

  public int getSecret() {
    return secret;
  }
}
