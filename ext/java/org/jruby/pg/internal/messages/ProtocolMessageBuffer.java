package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

public class ProtocolMessageBuffer {
  private final ByteBuffer first5Bytes = ByteBuffer.allocate(5);
  private ByteBuffer rest;
  private byte firstByte;
  private int messageSize;
  private ProtocolMessage message;

  public int remaining() {
    createRestBuffer();
    if (rest != null)
      return rest.remaining();
    return first5Bytes.remaining();
  }

  public ByteBuffer getBuffer() {
    createRestBuffer();
    if (rest != null) {
      return rest;
    }
    return first5Bytes;
  }

  private void createRestBuffer() {
    if (first5Bytes.remaining() == 0 && rest == null) {
      first5Bytes.flip();
      firstByte = first5Bytes.get();
      messageSize = first5Bytes.getInt();
      rest = ByteBuffer.allocate(messageSize - 4);
    }
  }

  public ProtocolMessage getMessage() {
    if (message != null) return message;
    message = translateBuffer();
    return message;
  }

  private ProtocolMessage translateBuffer() {
    if (rest == null || rest.remaining() != 0)
      throw new IllegalStateException("message is incomplete");

    rest.flip();
    switch(firstByte) {
    case 'R':
      switch(rest.getInt()) {
      case 0:
        return new AuthenticationOk();
      case 2:
        return new AuthenticationKerbosV5();
      case 3:
        return new AuthenticationCleartextPassword();
      case 4:
        byte[] salt = new byte[2];
        rest.get(salt);
        return new AuthenticationCryptPassword(salt);
      case 5:
        byte[] md5Salt = new byte[4];
        rest.get(md5Salt);
        return new AuthenticationMD5Password(md5Salt);
      case 6:
        return new AuthenticationSCMCredential();
      default:
        throw new IllegalArgumentException("Unknown authentication type");
      }
    case 'S':
      ByteBuffer _parameterName = ByteUtils.getNullTerminatedBytes(rest);
      ByteBuffer _parameterValue = ByteUtils.getNullTerminatedBytes(rest);
      String parameterName = ByteUtils.byteBufferToString(_parameterName);
      String parameterValue = ByteUtils.byteBufferToString(_parameterValue);
      return new ParameterStatus(parameterName, parameterValue);
    case 'T':
      int numberOfColumns = rest.getShort();
      Column[] columns = new Column[numberOfColumns];
      for (int i = 0; i < numberOfColumns; i++) {
        ByteBuffer _name = ByteUtils.getNullTerminatedBytes(rest);
        String name = ByteUtils.byteBufferToString(_name);
        int tableOid = rest.getInt();
        int tableIndex = rest.getShort();
        int oid = rest.getInt();
        int size = rest.getShort();
        int typmod = rest.getInt();
        int format = rest.getShort();
        columns[i] = new Column(name, tableOid, tableIndex, oid, size, typmod, format);
      }
      return new RowDescription(columns, rest.capacity() + 4);
    case 'D':
      int numberOfDataColumns = rest.getShort();
      ByteBuffer[] data = new ByteBuffer[numberOfDataColumns];
      for (int i = 0; i < numberOfDataColumns; i++) {
        int byteLength = rest.getInt();
        if (byteLength == -1) {
          data[i] = null;
        } else {
          ByteBuffer newBuffer = rest.duplicate();
          newBuffer.limit(rest.position() + byteLength);
          rest.position(newBuffer.limit());
          data[i] = newBuffer;
        }
      }
      return new DataRow(data, rest.capacity());
    case 'K':
      int pid = rest.getInt();
      int secret = rest.getInt();
      return new BackendKeyData(pid, secret);
    case 'E':
    case 'N':
      byte code;
      Map<Byte, String> fields = new HashMap<Byte, String>();
      while((code = rest.get()) != '\0') {
        ByteBuffer value = ByteUtils.getNullTerminatedBytes(rest);
        fields.put(code, ByteUtils.byteBufferToString(value));
      }
      if (firstByte == 'E')
        return new ErrorResponse(fields, rest.capacity() + 4);
      else
        return new NoticeResponse(fields, rest.capacity() + 4);
    case 'C':
      ByteBuffer buffer = ByteUtils.getNullTerminatedBytes(rest);
      return new CommandComplete(ByteUtils.byteBufferToString(buffer));
    case 't':
      short length = rest.getShort();
      int [] oids = new int[length];
      for (int i = 0; i < length; i++)
        oids[i] = rest.getInt();
      return new ParameterDescription(oids, rest.capacity());
    case '1':
      return new ParseComplete();
    case '2':
      return new BindComplete();
    case 'A':
      pid = rest.getInt();
      String condition = ByteUtils.byteBufferToString(ByteUtils.getNullTerminatedBytes(rest));
      ByteBuffer payloadBytes = ByteUtils.getNullTerminatedBytes(rest);
      String payload;
      if (payloadBytes.remaining() == 0)
        payload = null;
      else
        payload = ByteUtils.byteBufferToString(payloadBytes);
      return new NotificationResponse(pid, condition, payload);
    case 'G':
      Format overallFormat = Format.isBinary(rest.get()) ? Format.Binary : Format.Text;
      short numberOfFormats = rest.getShort();
      Format [] formats = new Format[numberOfFormats];
      for (int i = 0; i < numberOfFormats; i++)
        formats[i] = Format.isBinary(rest.getShort()) ? Format.Binary : Format.Text;
      return new CopyInResponse(overallFormat, formats);
    case 'H':
      overallFormat = Format.isBinary(rest.get()) ? Format.Binary : Format.Text;
      numberOfFormats = rest.getShort();
      formats = new Format[numberOfFormats];
      for (int i = 0; i < numberOfFormats; i++)
        formats[i] = Format.isBinary(rest.getShort()) ? Format.Binary : Format.Text;
      return new CopyOutResponse(overallFormat, formats);
    case 'd':
      return new CopyData(rest);
    case 'c':
      return new CopyDone();
    case 'n':
      return new NoData();
    case 'Z':
      byte transactionStatus = rest.get();
      return new ReadyForQuery(TransactionStatus.fromByte(transactionStatus), rest.capacity() + 4);
    default:
      throw new IllegalArgumentException("Cannot translate buffer to message for type '" + ((char) firstByte) + "'");
    }
  }
}
