package org.jruby.pg.internal.messages;

import java.nio.ByteBuffer;

public abstract class ProtocolMessage {
  public static enum MessageType {
    AuthenticationOk,
    AuthenticationKerbosV5,
    AuthenticationCleartextPassword,
    AuthenticationCryptPassword,
    AuthenticationMD5Password,
    AuthenticationSCMCredential,
    BackendKeyData,
    Bind,
    BindComplete,
    CancelRequest,
    Close,
    CloseComplete,
    CommandComplete,
    CopyData,
    CopyDone,
    CopyFail,
    CopyInResponse,
    CopyOutResponse,
    DataRow,
    Describe,
    EmptyQueryResponse,
    ErrorResponse,
    Execute,
    Flush,
    FunctionCall,
    FunctionCallResponse,
    NoData,
    NoticeResponse,
    NotificationResponse,
    ParameterDescription,
    ParameterStatus,
    Parse,
    ParseComplete,
    PasswordMessage,
    PortalSuspended,
    Query,
    ReadyForQuery,
    RowDescription,
    SSLRequest,
    StartupMessage,
    Sync,
    Terminate;

    public byte getFirstByte() {
      switch (this) {
      case AuthenticationOk:
      case AuthenticationKerbosV5:
      case AuthenticationCleartextPassword:
      case AuthenticationCryptPassword:
      case AuthenticationMD5Password:
      case AuthenticationSCMCredential:
        return 'R';
      case BackendKeyData:
        return 'K';
      case Bind:
        return 'B';
      case BindComplete:
        return '2';
      case CancelRequest:
        return '\0';
      case Close:
        return 'C';
      case CloseComplete:
        return '3';
      case CommandComplete:
        return 'C';
      case CopyData:
        return 'd';
      case CopyDone:
        return 'c';
      case CopyFail:
        return 'f';
      case CopyInResponse:
        return 'G';
      case CopyOutResponse:
        return 'H';
      case DataRow:
        return 'D';
      case Describe:
        return 'D';
      case EmptyQueryResponse:
        return 'I';
      case ErrorResponse:
        return 'E';
      case Execute:
        return 'E';
      case Flush:
        return 'H';
      case FunctionCall:
        return 'F';
      case FunctionCallResponse:
        return 'V';
      case NoData:
        return 'n';
      case NoticeResponse:
        return 'N';
      case NotificationResponse:
        return 'A';
      case ParameterDescription:
        return 't';
      case ParameterStatus:
        return 'S';
      case Parse:
        return 'P';
      case ParseComplete:
        return '1';
      case PasswordMessage:
        return 'p';
      case PortalSuspended:
        return 's';
      case Query:
        return 'Q';
      case ReadyForQuery:
        return 'Z';
      case RowDescription:
        return 'T';
      case SSLRequest:
        return '\0';
      case StartupMessage:
        return '\0';
      case Sync:
        return 'S';
      case Terminate:
        return 'X';
      default:
        throw new IllegalArgumentException("Unknown type: " + name());
      }
    }
  }

  public byte getFirstByte() {
    return getType().getFirstByte();
  }
  public abstract int getLength();
  public abstract MessageType getType();
  public abstract ByteBuffer toBytes();
}
