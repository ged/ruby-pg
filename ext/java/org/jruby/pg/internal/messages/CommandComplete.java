package org.jruby.pg.internal.messages;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class CommandComplete extends BackendMessage {
  private static final Pattern COMMANDS = Pattern.compile("(INSERT|DELETE|UPDATE|MOVE|FETCH)(\\s+\\d+)?\\s+(\\d+)");

  private final String command;
  private final int oid;
  private final int rows;
  private final String tag;

  public CommandComplete(String tag) {
    this.tag = tag;
    Matcher matcher = COMMANDS.matcher(tag);
    if (matcher.matches()) {
      command = matcher.group(1);
      rows = Integer.parseInt(matcher.group(3));
      oid = matcher.group(2) == null ? -1 : Integer.parseInt(matcher.group(2).trim());
    } else {
      command = tag;
      oid = -1;
      rows = 0;
    }
  }

  @Override
  public int getLength() {
    return 4 + tag.getBytes().length;
  }

  @Override
  public MessageType getType() {
    return MessageType.CommandComplete;
  }

  public String getTag() {
    return tag;
  }

  public String getCommand() {
    return command;
  }

  public int getOid() {
    return oid;
  }

  public int getRows() {
    return rows;
  }
}
