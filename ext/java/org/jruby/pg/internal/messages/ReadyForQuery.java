package org.jruby.pg.internal.messages;

public class ReadyForQuery extends BackendMessage {
  private final TransactionStatus transactionStatus;
  private final int length;

  public ReadyForQuery(TransactionStatus transactionStatus, int length) {
    this.transactionStatus = transactionStatus;
    this.length = length;
  }

  @Override
  public int getLength() {
    return length;
  }

  @Override
  public MessageType getType() {
    return MessageType.ReadyForQuery;
  }

  public TransactionStatus getTransactionStatus() {
    return transactionStatus;
  }
}
