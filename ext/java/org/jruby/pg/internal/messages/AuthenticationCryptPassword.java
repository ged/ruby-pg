package org.jruby.pg.internal.messages;

public class AuthenticationCryptPassword extends BackendMessage {
  public AuthenticationCryptPassword(byte[] salt) {
    if (salt.length != 2)
      throw new IllegalArgumentException("argument must be a 2 byte array");
  }

  @Override
  public int getLength() {
    return 10;
  }

  @Override
  public MessageType getType() {
    return MessageType.AuthenticationCryptPassword;
  }
}
