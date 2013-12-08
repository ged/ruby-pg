package org.jruby.pg.internal;

import java.io.IOException;
import java.nio.ByteBuffer;

import org.jruby.pg.internal.messages.Format;

/**
 * select proname, pronargs, proargtypes from pg_catalog.pg_proc where proname
 * like 'lo%'; proname | pronargs | proargtypes | prorettype
 * ------------+----------+-------------+------------ lo_import | 1 | 25 | 26
 * lo_import | 2 | 25 26 | 26 lo_export | 2 | 26 25 | 23 lo_open | 2 | 26 23 |
 * 23 lo_close | 1 | 23 | 23 loread | 2 | 23 23 | 17 lowrite | 2 | 23 17 | 23
 * lo_lseek | 3 | 23 23 23 | 23 lo_creat | 1 | 23 | 26 lo_create | 1 | 26 | 26
 * lo_tell | 1 | 23 | 23 lo_truncate | 2 | 23 23 | 23 lo_unlink | 1 | 26 | 23
 *
 * ================================================================
 *
 * SELECT oid,typname from pg_catalog.pg_type where oid in (13, 17, 23, 25, 26);
 * oid | typname -----+--------- 17 | bytea 23 | int4 25 | text 26 | oid
 *
 * ================================================================
 *
 * @author jvshahid
 */
public class LargeObjectAPI {
  public static final int WRITE = 0x00020000;
  public static final int READ  = 0x00040000;
  public static final int SEEK_SET = 0;
  public static final int SEEK_CUR = 1;
  public static final int SEEK_END = 2;

  public LargeObjectAPI(PostgresqlConnection postgresqlConnection) {
    this.postgresqlConnection = postgresqlConnection;
  }

  public int loCreate(int oid) throws IOException, PostgresqlException {
    return createCommon("lo_create", oid);
  }

  public int loCreat(int mode) throws IOException, PostgresqlException {
    return createCommon("lo_creat", mode);
  }

  public int loOpen(int oid) throws IOException, PostgresqlException {
    return loOpen(oid, READ | WRITE);
  }

  public int loOpen(int oid, int mode) throws IOException, PostgresqlException {
    return twoArgFunction("lo_open", oid, mode);
  }

  private int createCommon(String functionName, int argValue) throws IOException, PostgresqlException {
    ByteBuffer buffer = ByteBuffer.allocate(4);
    buffer.putInt(argValue);
    Value value = new Value(buffer.array(), Format.Binary);
    ResultSet result = postgresqlConnection.execQueryParams(createString("select " + functionName + "($1)"), new Value[] { value },
        Format.Binary, new int[0]);
    if (result.hasError()) {
      throw new PostgresqlException(result.getError().getErrorMesssage(), result);
    }
    buffer = result.getRows().get(0).getValues()[0];
    return buffer.getInt();
  }

  private final PostgresqlConnection postgresqlConnection;

  public int loWrite(int fd, byte[] bytes) throws IOException, PostgresqlException {
    ByteBuffer buffer = ByteBuffer.allocate(4);
    buffer.putInt(fd);
    Value fdValue = new Value(buffer.array(), Format.Binary);
    Value byteValue = new Value(bytes, Format.Binary);
    ResultSet result = postgresqlConnection.execQueryParams(createString("select lowrite($1, $2)"),
        new Value[] { fdValue, byteValue }, Format.Binary, new int[0]);
    if (result.hasError()) {
      throw new PostgresqlException(result.getError().getErrorMesssage(), result);
    }
    buffer = result.getRows().get(0).getValues()[0];
    return buffer.getInt();
  }

  public byte[] loRead(int fd, int count) throws PostgresqlException, IOException {
    ByteBuffer buffer = ByteBuffer.allocate(4);
    byte[] fdBytes, countBytes;
    fdBytes = new byte[4];
    countBytes = new byte[4];
    buffer.putInt(fd);
    buffer.flip();
    buffer.get(fdBytes);
    buffer.clear();
    buffer.putInt(count);
    buffer.flip();
    buffer.get(countBytes);

    Value fdValue = new Value(fdBytes, Format.Binary);
    Value countValue = new Value(countBytes, Format.Binary);
    ResultSet result = postgresqlConnection.execQueryParams(createString("select loread($1, $2)"),
        new Value[] { fdValue, countValue }, Format.Binary, new int[0]);
    if (result.hasError()) {
      throw new PostgresqlException(result.getError().getErrorMesssage(), result);
    }
    ByteBuffer value = result.getRows().get(0).getValues()[0];
    byte[] bytes = new byte[value.remaining()];
    value.get(bytes);
    return bytes;
  }

  public int loSeek(int fd, int offset, int whence) throws IOException, PostgresqlException {
    ByteBuffer buffer = ByteBuffer.allocate(4);
    byte[] fdBytes, offsetBytes, whenceBytes;
    fdBytes = new byte[4];
    offsetBytes = new byte[4];
    whenceBytes = new byte[4];
    buffer.putInt(fd);
    buffer.flip();
    buffer.get(fdBytes);
    buffer.clear();
    buffer.putInt(offset);
    buffer.flip();
    buffer.get(offsetBytes);
    buffer.clear();
    buffer.putInt(whence);
    buffer.flip();
    buffer.get(whenceBytes);

    Value fdValue = new Value(fdBytes, Format.Binary);
    Value offsetValue = new Value(offsetBytes, Format.Binary);
    Value whenceValue = new Value(whenceBytes, Format.Binary);
    ResultSet result = postgresqlConnection.execQueryParams(createString("select lo_lseek($1, $2, $3)"), new Value[] { fdValue,
        offsetValue, whenceValue }, Format.Binary, new int[0]);
    if (result.hasError()) {
      throw new PostgresqlException(result.getError().getErrorMesssage(), result);
    }
    ByteBuffer value = result.getRows().get(0).getValues()[0];
    return value.getInt();
  }

  public int loTell(int fd) throws IOException, PostgresqlException {
    return oneArgFunction("lo_tell", fd);
  }

  public int loClose(int fd) throws IOException, PostgresqlException {
    return oneArgFunction("lo_close", fd);
  }

  public int loUnlink(int fd) throws IOException, PostgresqlException {
    return oneArgFunction("lo_unlink", fd);
  }

  private int oneArgFunction(String name, int fd) throws IOException, PostgresqlException {
    ByteBuffer buffer = ByteBuffer.allocate(4);
    byte[] fdBytes;
    fdBytes = new byte[4];
    buffer.putInt(fd);
    buffer.flip();
    buffer.get(fdBytes);

    Value fdValue = new Value(fdBytes, Format.Binary);
    ResultSet result = postgresqlConnection.execQueryParams(createString("select " + name + "($1)"), new Value[] { fdValue }, Format.Binary, new int[0]);
    if (result.hasError()) {
      throw new PostgresqlException(result.getError().getErrorMesssage(), result);
    }
    ByteBuffer value = result.getRows().get(0).getValues()[0];
    return value.getInt();
  }

  public int loTruncate(int fd, int len) throws PostgresqlException, IOException {
    return twoArgFunction("lo_truncate", fd, len);
  }

  private int twoArgFunction(String name, int value1, int value2) throws PostgresqlException, IOException {
    ByteBuffer buffer = ByteBuffer.allocate(4);
    byte[] value1Bytes, value2Bytes;
    value1Bytes = new byte[4];
    value2Bytes = new byte[4];
    buffer.putInt(value1);
    buffer.flip();
    buffer.get(value1Bytes);
    buffer.clear();
    buffer.putInt(value2);
    buffer.flip();
    buffer.get(value2Bytes);

    Value value1Value = new Value(value1Bytes, Format.Binary);
    Value value2Value = new Value(value2Bytes, Format.Binary);
    ResultSet result = postgresqlConnection.execQueryParams(createString("select " + name + "($1, $2)"),
        new Value[] { value1Value, value2Value }, Format.Binary, new int[0]);
    if (result.hasError()) {
      throw new PostgresqlException(result.getError().getErrorMesssage(), result);
    }
    ByteBuffer value = result.getRows().get(0).getValues()[0];
    return value.getInt();
  }

  private PostgresqlString createString(String value) {
    return new PostgresqlString(value);
  }
}
