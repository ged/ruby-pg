package org.jruby.pg.internal.io;

import java.io.IOException;
import java.net.SocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ClosedChannelException;
import java.nio.channels.SelectableChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;
import java.security.NoSuchAlgorithmException;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLEngineResult;
import javax.net.ssl.SSLEngineResult.HandshakeStatus;
import javax.net.ssl.SSLEngineResult.Status;
import javax.net.ssl.SSLException;

public class SecureSocketWrapper implements SocketWrapper {
  private final SocketChannel channel;
  private final SSLEngine     sslEngine;

  private final ByteBuffer    in;
  private final ByteBuffer    unwrappedIn;
  private final ByteBuffer    out;
  private final ByteBuffer    empty;

  private boolean             isPuttingInUnwrappedInBuffer = true;
  private boolean             isPuttingInInBuffer          = true;
  private boolean             isPuttingInOutBuffer         = true;
  private Status lastStatus;

  public SecureSocketWrapper(SocketWrapper wrapper) throws NoSuchAlgorithmException {
    this.channel = wrapper.getSocket();
    SSLContext context = SSLContext.getDefault();
    sslEngine = context.createSSLEngine();
    sslEngine.setUseClientMode(true);
    in = ByteBuffer.allocate(sslEngine.getSession().getPacketBufferSize());
    unwrappedIn = ByteBuffer.allocate(sslEngine.getSession().getApplicationBufferSize());
    out = ByteBuffer.allocate(sslEngine.getSession().getPacketBufferSize());
    empty = ByteBuffer.allocate(0);
  }

  @Override
  public SelectionKey register(Selector sel, int ops) throws ClosedChannelException {
    return channel.register(sel, ops);
  }

  @Override
  public boolean connect(SocketAddress remote) throws IOException {
    return channel.connect(remote);
  }

  @Override
  public SelectableChannel configureBlocking(boolean block) throws IOException {
    return channel.configureBlocking(block);
  }

  @Override
  public void doHandshake() throws SSLException, IOException {
    channel.configureBlocking(false);
    sslEngine.beginHandshake();
    HandshakeStatus handshakeStatus = sslEngine.getHandshakeStatus();
    outerloop: while (true) {
      Selector selector = Selector.open();
      switch (handshakeStatus) {
      case NEED_UNWRAP:
        if (isPuttingInInBuffer) {
          channel.register(selector, SelectionKey.OP_READ);
          selector.select();
          channel.read(in);
          if (in.remaining() > 0) {
            isPuttingInInBuffer = false;
            in.flip();
          }
        } else {
          SSLEngineResult inResult = sslEngine.unwrap(in, unwrappedIn);
          handshakeStatus = inResult.getHandshakeStatus();
          if (in.remaining() == 0) {
            in.clear();
            isPuttingInInBuffer = true;
          }
        }
        break;
      case NEED_WRAP:
        SSLEngineResult outResult = sslEngine.wrap(empty, out);
        handshakeStatus = outResult.getHandshakeStatus();
        if (outResult.bytesProduced() > 0) {
          out.flip();
          channel.register(selector, SelectionKey.OP_WRITE);
          while (out.remaining() != 0) {
            selector.select();
            channel.write(out);
          }
          out.clear();
        }
        break;
      case NEED_TASK:
        Runnable runnable;
        while ((runnable = sslEngine.getDelegatedTask()) != null)
          runnable.run();
        handshakeStatus = sslEngine.getHandshakeStatus();
        break;
      case FINISHED:
        break outerloop;
      default:
        throw new SSLException("Doesn't know how to handle this case: " + sslEngine.getHandshakeStatus().name());
      }
      selector.close();
    }
    out.clear();
    in.clear();
    unwrappedIn.clear();
    isPuttingInInBuffer = true;
    isPuttingInUnwrappedInBuffer = true;
    isPuttingInOutBuffer = true;
  }

  @Override
  public int read(ByteBuffer buffer) throws IOException {
    if (!isPuttingInUnwrappedInBuffer) {
      while (buffer.remaining() > 0 && unwrappedIn.remaining() > 0)
        buffer.put(unwrappedIn.get());
      if (unwrappedIn.remaining() == 0) {
        isPuttingInUnwrappedInBuffer = true;
        unwrappedIn.clear();
      }
      return 0;
    }
    if (isPuttingInInBuffer) {
      int read = channel.read(in);
      if (in.remaining() > 0) {
        in.flip();
        isPuttingInInBuffer = false;
      } else {
        return read;
      }
    }
    SSLEngineResult result = sslEngine.unwrap(in, unwrappedIn);
    lastStatus = result.getStatus();
    unwrappedIn.flip();
    isPuttingInUnwrappedInBuffer = false;
    if (in.remaining() == 0) {
      in.clear();
      isPuttingInInBuffer = true;
    }
    return read(buffer);
  }

  @Override
  public int write(ByteBuffer buffer) throws IOException {
    if (!isPuttingInOutBuffer) {
      if (out.remaining() != 0)
        return channel.write(out);
      out.clear();
      isPuttingInOutBuffer = true;
    }
    sslEngine.wrap(buffer, out);
    isPuttingInOutBuffer = false;
    out.flip();
    return channel.write(out);
  }

  @Override
  public int outBufferRemaining() {
    return out.remaining();
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
    if (lastStatus == Status.BUFFER_UNDERFLOW) {
      return true;
    }
    return isPuttingInUnwrappedInBuffer ? in.remaining() == 0 : unwrappedIn.remaining() == 0;
  }
}
