package org.jruby.pg.internal.messages;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.PostgresqlString;

public class ByteUtils {
  public static void writeInt4(OutputStream out, int value) throws IOException {
    out.write(value >> 24);
    out.write(value >> 16);
    out.write(value >> 8);
    out.write(value);
  }

  public static void writeInt2(OutputStream out, int value) throws IOException {
    out.write(value >> 8);
    out.write(value);
  }

  public static ByteBuffer getNullTerminatedBytes(ByteBuffer buffer) {
    return getNullTerminatedBytes(buffer, 0);
  }

  public static ByteBuffer getNullTerminatedBytes(ByteBuffer buffer, int offset) {
    ByteBuffer newBuffer = buffer.duplicate();
    byte[] bytes = newBuffer.array();
    int i;
    int position = buffer.position() + buffer.arrayOffset() + offset;
    for (i = position; i < newBuffer.limit(); i++)
      if (bytes[i] == '\0')
        break;
    newBuffer.position(position - buffer.arrayOffset());
    newBuffer.limit(i);
    buffer.position(i + 1);	// skip the null byte
    return newBuffer;
  }

  public static String byteBufferToString(ByteBuffer buffer) {
    int position = buffer.position();
    int limit = buffer.limit();
    return new String(buffer.array(), position, limit - position);
  }

  public static void fixLength(byte[] bytes) {
    fixLength(bytes, 1);
  }

  public static void fixLength(byte[] bytes, int offset) {
    int length = bytes.length - offset;
    bytes[offset]     = (byte) (length >> 24);
    bytes[offset + 1] = (byte) (length >> 16);
    bytes[offset + 2] = (byte) (length >> 8);
    bytes[offset + 3] = (byte) (length);
  }

  public static void writeString(OutputStream out, String name) throws IOException {
    out.write(name.getBytes());
    out.write('\0');
  }

  public static void writeString(OutputStream out, PostgresqlString name) throws IOException {
    out.write(name.getBytes());
    out.write('\0');
  }
}
