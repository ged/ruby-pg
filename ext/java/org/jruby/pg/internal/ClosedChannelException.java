package org.jruby.pg.internal;

import java.io.IOException;

public class ClosedChannelException extends IOException {
  public ClosedChannelException(String message) {
    super(message);
  }
}
