package org.jruby.pg.internal;

import java.io.IOException;
import java.net.SocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.SelectableChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;

import org.jruby.pg.internal.io.SocketWrapper;

public class NonSecureSocketWrapper implements SocketWrapper {
  private final SocketChannel channel;

  public NonSecureSocketWrapper(SocketChannel channel) {
    this.channel = channel;
  }

  @Override
  public SelectableChannel configureBlocking(boolean block) throws IOException {
    return channel.configureBlocking(block);
  }

  @Override
  public int read(ByteBuffer buffer) throws IOException {
    return channel.read(buffer);
  }

  @Override
  public int write(ByteBuffer buffer) throws IOException {
    return channel.write(buffer);
  }

  @Override
  public boolean connect(SocketAddress remote) throws IOException {
    return channel.connect(remote);
  }

  @Override
  public SelectionKey register(Selector sel, int ops) throws ClosedChannelException {
    return channel.register(sel, ops);
  }

  @Override
  public void doHandshake() {
    // we don't need to do any handshaking
  }

  @Override
  public int outBufferRemaining() {
    return 0;
  }

  @Override
  public SocketChannel getSocket() {
    return channel;
  }

  @Override
  public void close() throws IOException {
    channel.close();
  }

  @Override
  public boolean shouldWaitForData() {
    return true;
  }
}
