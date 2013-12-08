package org.jruby.pg.internal;

import java.nio.charset.Charset;

public class PostgresqlString {
  public static final PostgresqlString NULL_STRING = new PostgresqlString(new byte[0]) {
    @Override
    public byte[] getBytes() {
      return bytes;
    }
  };

  byte[] bytes;

  public PostgresqlString(byte[] bytes) {
    this.bytes = bytes;
  }

  public PostgresqlString(String value) {
    this.bytes = value.getBytes();
  }

  public PostgresqlString(String value, Charset charset) {
    this.bytes = value.getBytes(charset);
  }

  public byte[] getBytes() {
    byte[] bytes = new byte[this.bytes.length];
    System.arraycopy(this.bytes, 0, bytes, 0, bytes.length);
    return bytes;
  }
}
