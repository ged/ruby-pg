package org.jruby.pg.internal.messages;

public abstract class CopyResponse extends BackendMessage {
  private final Format overallFormat;
  private final Format[] columnFormats;

  public CopyResponse(Format overallFormat, Format[] columnFormats) {
    this.overallFormat = overallFormat;
    this.columnFormats = columnFormats;
  }

  @Override
  public int getLength() {
    return 4 + 1 + 2 + 2 * columnFormats.length;
  }

  public Format getOverallFormat() {
    return overallFormat;
  }

  public Format[] getColumnFormats() {
    return columnFormats;
  }
}
