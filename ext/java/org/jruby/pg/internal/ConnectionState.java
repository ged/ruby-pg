package org.jruby.pg.internal;

import org.jruby.pg.internal.messages.ProtocolMessage.MessageType;

public enum ConnectionState {
  CONNECTION_OK,
  CONNECTION_BAD,
  PGRES_POLLING_READING,
  PGRES_POLLING_WRITING,
  PGRES_POLLING_OK,
  PGRES_POLLING_FAILED,

  Closed,

  // Connecting,
  ReadingNotifications,
  ReadingAuthenticationResponse,
  ReadingParameterStatus,
  ReadingBackendData,
  ReadingAuthentication,
  ReadingQueryResponse,
  ReadingParseResponse,
  ReadingBindResponse,
  ReadingDescribeResponse,
  ReadingExecuteResponse,
  ReadingReadyForQuery,

  NewCopyInState,
  NewCopyOutState,
  NewExtendedCopyInState,
  NewExtendedCopyOutState,
  NewCopyDone,
  NewExtendedCopyDone,

  SendingStartup,
  SendingAuthentication,
  SendingQuery,
  SendingParse,
  SendingParseFlush,
  SendingBind,
  SendingBindFlush,
  SendingDescribe,
  SendingDescribeFlush,
  SendingExecute,
  SendingExecuteFlush,
  SendingSync,

  ExtendedReadyForQuery,
  ReadyForQuery,
  Failed;

  public ConnectionState nextState() {
    switch (this) {
    case SendingAuthentication:
      return ReadingAuthenticationResponse;
    case SendingQuery:
      return ReadingQueryResponse;
    case SendingStartup:
      return ReadingAuthentication;
    case SendingDescribe:
      return SendingDescribeFlush;
    case SendingDescribeFlush:
      return ReadingDescribeResponse;
    case SendingParse:
      return SendingParseFlush;
    case SendingParseFlush:
      return ReadingParseResponse;
    case SendingBind:
      return SendingBindFlush;
    case SendingBindFlush:
      return ReadingBindResponse;

    case NewCopyInState:
    case NewExtendedCopyInState:
      return this;
    case NewCopyDone:
      return ReadingQueryResponse;
    case NewExtendedCopyDone:
      return ReadingExecuteResponse;

    case SendingExecute:
      return SendingExecuteFlush;
    case SendingExecuteFlush:
      return ReadingExecuteResponse;	// this is similar to ReadingQueryResponse
    case SendingSync:
      return ReadingReadyForQuery;
    default:
      throw new IllegalArgumentException("this method can be used for sending states only");
    }
  }

  public ConnectionState nextState(MessageType receivedMessageType) {
    if (receivedMessageType == MessageType.NoticeResponse ||
        receivedMessageType == MessageType.ParameterStatus ||
        receivedMessageType == MessageType.NotificationResponse)
      return this;

    if (receivedMessageType == MessageType.ErrorResponse) {
      switch (this) {
      case ReadingParseResponse:
      case ReadingDescribeResponse:
      case ReadingExecuteResponse:
      case ReadingBindResponse:
        return ExtendedReadyForQuery;
      case ReadingAuthentication:
      case ReadingAuthenticationResponse:
      case ReadingBackendData:
      case ReadingParameterStatus:
        return Failed;
      case ReadingQueryResponse:
        return this;
      }
    }

    switch (this) {
    case ReadingAuthentication:
    case ReadingAuthenticationResponse:
      switch (receivedMessageType) {
      case AuthenticationCleartextPassword:
      case AuthenticationMD5Password:
        return SendingAuthentication;
      case AuthenticationOk:
        return ReadingBackendData;
      }
      break;
    case ReadingBackendData:
    case ReadingParameterStatus:
      switch (receivedMessageType) {
      case ReadyForQuery:
        return ReadyForQuery;
      case ParameterStatus:
      case BackendKeyData:
        return this;
      }
      break;
    case ReadingParseResponse:
      return ExtendedReadyForQuery;
    case ReadingBindResponse:
      return ExtendedReadyForQuery;
    case ReadingDescribeResponse:
      switch (receivedMessageType) {
      case NoData:
        return ExtendedReadyForQuery;
      case RowDescription:
        return ExtendedReadyForQuery;
      case ParameterDescription:
        return this;
      }
    case SendingSync:
      return ReadyForQuery;
    case ReadingExecuteResponse:
      switch(receivedMessageType) {
      case CommandComplete:
        return ExtendedReadyForQuery;
      case CopyInResponse:
        return NewExtendedCopyInState;
      case CopyOutResponse:
        return NewExtendedCopyOutState;
      }
    case ReadingQueryResponse:
      switch (receivedMessageType) {
      case CopyInResponse:
        return NewCopyInState;
      case CopyOutResponse:
        return NewCopyOutState;
      case CommandComplete:
      case EmptyQueryResponse:
      case RowDescription:
      case DataRow:
        return this;
      case ReadyForQuery:
        return ReadyForQuery;
      }
    case NewCopyOutState:
    case NewExtendedCopyOutState:
      switch (receivedMessageType) {
      case CopyData:
        return this;
      case CopyDone:
      case ErrorResponse:
        return this == NewCopyOutState ? ReadingQueryResponse : ReadingExecuteResponse;
      default:
        throw new IllegalArgumentException("Unexpected message type: " + receivedMessageType.name());
      }
    case ReadingReadyForQuery:
      switch(receivedMessageType) {
      case ReadyForQuery:
        return ReadyForQuery;
      default:
        throw new IllegalArgumentException("Unexpected message type: " + receivedMessageType.name());
      }
    }

    throw new UnsupportedOperationException("Unexpected message of type " + receivedMessageType.name() + " received in " + name());
  }

  public boolean isRead() {
    switch (this) {
    case ReadingAuthenticationResponse:
    case ReadingAuthentication:
    case ReadingParameterStatus:
    case ReadingBackendData:
    case ReadingNotifications:
    case ReadingQueryResponse:
    case ReadingParseResponse:
    case ReadingBindResponse:
    case ReadingDescribeResponse:
    case ReadingExecuteResponse:
    case ReadingReadyForQuery:
    case NewCopyOutState:
    case NewExtendedCopyOutState:
      return true;
    default:
      return false;
    }
  }

  public boolean isWrite() {
    switch (this) {
    case SendingAuthentication:
    case SendingQuery:
    case SendingStartup:
    case SendingSync:
    case SendingParse:
    case SendingParseFlush:
    case SendingBind:
    case SendingBindFlush:
    case SendingDescribe:
    case SendingDescribeFlush:
    case SendingExecute:
    case SendingExecuteFlush:
    case NewCopyInState:
    case NewExtendedCopyInState:
    case NewCopyDone:
      return true;
    default:
      return false;
    }
  }

  public boolean isCopyOut() {
    switch (this) {
    case NewCopyOutState:
    case NewExtendedCopyOutState:
      return true;
    default:
      return false;
    }
  }

  public boolean isCopyIn() {
    switch (this) {
    case NewCopyInState:
    case NewExtendedCopyInState:
    case NewCopyDone:
      return true;
    default:
      return false;
    }
  }

  public boolean isFlush() {
    switch (this) {
    case SendingParseFlush:
    case SendingBindFlush:
    case SendingDescribeFlush:
    case SendingExecuteFlush:
      return true;
    default:
      return false;
    }
  }

  public boolean isSync() {
    switch (this) {
    case SendingSync:
    case ReadingReadyForQuery:
      return true;
    default:
      return false;
    }
  }

  public boolean isIdle() {
    switch (this) {
    case ReadyForQuery:
    case Closed:
      return true;
    default:
      return false;
    }
  }

  public boolean isFail() {
    switch (this) {
    case Failed:
      return true;
    default:
      return false;
    }
  }

  public ConnectionState pollingState() {
    switch(this) {
    case SendingStartup:
    case SendingAuthentication:
      return ConnectionState.PGRES_POLLING_WRITING;
    case ReadingAuthentication:
    case ReadingAuthenticationResponse:
    case ReadingBackendData:
    case ReadingParameterStatus:
      return ConnectionState.PGRES_POLLING_READING;
    case ReadyForQuery:
      return ConnectionState.PGRES_POLLING_OK;
    case Failed:
    case Closed:
      return ConnectionState.PGRES_POLLING_FAILED;
    default:
      throw new IllegalStateException("Unkown state: " + name());
    }
  }

  public ConnectionState simpleState() {
    switch(this) {
    case Failed:
      return ConnectionState.CONNECTION_BAD;
    default:
      return ConnectionState.CONNECTION_OK;
    }
  }

  public boolean shouldBlock() {
    switch(this) {
    case SendingQuery:
    case ReadingQueryResponse:
    case SendingParse:
    case ReadingParseResponse:
    case SendingDescribe:
    case ReadingDescribeResponse:
    case SendingBind:
    case ReadingBindResponse:
    case SendingExecute:
    case ReadingExecuteResponse:
    case ExtendedReadyForQuery:
    case ReadingNotifications:
      return true;
    default:
      return false;
    }
  }
}
