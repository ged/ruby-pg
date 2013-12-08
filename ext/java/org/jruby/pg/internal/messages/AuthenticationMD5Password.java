package org.jruby.pg.internal.messages;

public class AuthenticationMD5Password extends BackendMessage {
  private final byte[] salt;

  public AuthenticationMD5Password(byte[] salt) {
    this.salt = salt;
    if (salt.length != 4)
      throw new IllegalArgumentException("Salt must be a 4 byte array");
  }

  @Override
  public int getLength() {
    return 12;
  }

  @Override
  public MessageType getType() {
    return MessageType.AuthenticationMD5Password;
  }

  public byte[] getSalt() {
    return salt;
  }
}
