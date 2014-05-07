package org.jruby.pg.internal.io;

import java.io.IOException;
import java.net.SocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.SelectableChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;

import javax.net.ssl.SSLException;

public interface SocketWrapper {
  int outBufferRemaining();
  boolean shouldWaitForData();
  SocketChannel getSocket();
  void doHandshake() throws SSLException, IOException;

  boolean connect(SocketAddress remote) throws IOException;
  SelectionKey register(Selector sel, int ops) throws ClosedChannelException;
  SelectableChannel configureBlocking(boolean block) throws IOException;
  int read(ByteBuffer buffer) throws IOException;
  int write(ByteBuffer buffer) throws IOException;
  void close() throws IOException;
}
