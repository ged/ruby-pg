package org.jruby.pg.internal.messages;

public enum TransactionStatus {
  PQTRANS_IDLE(0),
  PQTRANS_INTRANS(2),
  PQTRANS_INERROR(3),
  PQTRANS_UNKNOWN(4);

  private int c;

  private TransactionStatus(int c) {
    this.c = c;
  }

  public int getValue() {
    return c;
  }

  public static TransactionStatus fromByte(byte c) {
    switch(c) {
    case 'I':
      return PQTRANS_IDLE;
    case 'T':
      return PQTRANS_INTRANS;
    case 'E':
      return PQTRANS_INERROR;
    default:
      throw new IllegalArgumentException("Unknown transaction status '" + c + "'");
    }
  }
}
