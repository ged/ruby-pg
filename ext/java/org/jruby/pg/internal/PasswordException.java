package org.jruby.pg.internal;

import java.io.IOException;

public class PasswordException extends IOException {
  public PasswordException(String message) {
    super(message);
  }
}
