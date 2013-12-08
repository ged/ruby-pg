package org.jruby.pg.internal.messages;

public class CopyOutResponse extends CopyResponse {
  public CopyOutResponse(Format overallFormat, Format[] columnFormats) {
    super(overallFormat, columnFormats);
  }

  @Override
  public MessageType getType() {
    return MessageType.CopyOutResponse;
  }
}
