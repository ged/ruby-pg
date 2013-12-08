package org.jruby.pg.internal.messages;


public class AuthenticationSCMCredential extends BackendMessage {

  @Override
  public int getLength() {
    return 8;
  }

  @Override
  public MessageType getType() {
    return MessageType.AuthenticationSCMCredential;
  }

}
