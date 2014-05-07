
package org.jruby.pg;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintWriter;
import java.nio.ByteBuffer;
import java.nio.channels.SelectableChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map.Entry;
import java.util.Map;
import java.util.Properties;
import org.jcodings.Encoding;
import org.jruby.Ruby;
import org.jruby.RubyArray;
import org.jruby.RubyClass;
import org.jruby.RubyEncoding;
import org.jruby.RubyException;
import org.jruby.RubyFixnum;
import org.jruby.RubyFloat;
import org.jruby.RubyHash;
import org.jruby.RubyIO;
import org.jruby.RubyModule;
import org.jruby.RubyNumeric;
import org.jruby.RubyObject;
import org.jruby.RubyString;
import org.jruby.RubySymbol;
import org.jruby.anno.JRubyMethod;
import org.jruby.exceptions.RaiseException;
import org.jruby.pg.internal.ClosedChannelException;
import org.jruby.pg.internal.ConnectionState;
import org.jruby.pg.internal.LargeObjectAPI;
import org.jruby.pg.internal.PasswordException;
import org.jruby.pg.internal.PostgresqlConnection;
import org.jruby.pg.internal.PostgresqlException;
import org.jruby.pg.internal.PostgresqlString;
import org.jruby.pg.internal.ResultSet;
import org.jruby.pg.internal.Value;
import org.jruby.pg.internal.messages.CopyData;
import org.jruby.pg.internal.messages.ErrorResponse.ErrorField;
import org.jruby.pg.internal.messages.Format;
import org.jruby.pg.internal.messages.NotificationResponse;
import org.jruby.runtime.Arity;
import org.jruby.runtime.Block;
import org.jruby.runtime.ObjectAllocator;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.ByteList;

public class Connection extends RubyObject {
  private final static String[]            POSITIONAL_ARGS                = {
      "host", "port", "options", "tty", "dbname", "user", "password"     };
    private final static Map<String, String> postgresEncodingToRubyEncoding = new HashMap<String, String>();
    private final static Map<String, String> rubyEncodingToPostgresEncoding = new HashMap<String, String>();
    protected final static int FORMAT_TEXT = 0;
    protected final static int FORMAT_BINARY = 1;

    protected static Connection LAST_CONNECTION = null;

    protected PostgresqlConnection postgresqlConnection;

    protected PostgresqlString BEGIN_QUERY = new PostgresqlString("BEGIN");
    protected PostgresqlString COMMIT_QUERY = new PostgresqlString("COMMIT");
    protected PostgresqlString ROLLBACK_QUERY = new PostgresqlString("ROLLBACK");
    private Properties props;

    static {
      postgresEncodingToRubyEncoding.put("BIG5",          "Big5"        );
      postgresEncodingToRubyEncoding.put("EUC_CN",        "GB2312"      );
      postgresEncodingToRubyEncoding.put("EUC_JP",        "EUC-JP"      );
      postgresEncodingToRubyEncoding.put("EUC_JIS_2004",  "EUC-JP"      );
      postgresEncodingToRubyEncoding.put("EUC_KR",        "EUC-KR"      );
      postgresEncodingToRubyEncoding.put("EUC_TW",        "EUC-TW"      );
      postgresEncodingToRubyEncoding.put("GB18030",       "GB18030"     );
      postgresEncodingToRubyEncoding.put("GBK",           "GBK"         );
      postgresEncodingToRubyEncoding.put("ISO_8859_5",    "ISO8859-5"  );
      postgresEncodingToRubyEncoding.put("ISO_8859_6",    "ISO8859-6"  );
      postgresEncodingToRubyEncoding.put("ISO_8859_7",    "ISO8859-7"  );
      postgresEncodingToRubyEncoding.put("ISO_8859_8",    "ISO8859-8"  );
      postgresEncodingToRubyEncoding.put("KOI8",          "KOI8-R"      );
      postgresEncodingToRubyEncoding.put("KOI8R",         "KOI8-R"      );
      postgresEncodingToRubyEncoding.put("KOI8U",         "KOI8-U"      );
      postgresEncodingToRubyEncoding.put("LATIN1",        "ISO8859-1"  );
      postgresEncodingToRubyEncoding.put("LATIN2",        "ISO8859-2"  );
      postgresEncodingToRubyEncoding.put("LATIN3",        "ISO8859-3"  );
      postgresEncodingToRubyEncoding.put("LATIN4",        "ISO8859-4"  );
      postgresEncodingToRubyEncoding.put("LATIN5",        "ISO8859-9"  );
      postgresEncodingToRubyEncoding.put("LATIN6",        "ISO8859-10" );
      postgresEncodingToRubyEncoding.put("LATIN7",        "ISO8859-13" );
      postgresEncodingToRubyEncoding.put("LATIN8",        "ISO8859-14" );
      postgresEncodingToRubyEncoding.put("LATIN9",        "ISO8859-15" );
      postgresEncodingToRubyEncoding.put("LATIN10",       "ISO8859-16" );
      postgresEncodingToRubyEncoding.put("MULE_INTERNAL", "Emacs-Mule"  );
      postgresEncodingToRubyEncoding.put("SJIS",          "Windows-31J" );
      postgresEncodingToRubyEncoding.put("SHIFT_JIS_2004","Windows-31J" );
      postgresEncodingToRubyEncoding.put("UHC",           "CP949"       );
      postgresEncodingToRubyEncoding.put("UTF8",          "UTF-8"       );
      postgresEncodingToRubyEncoding.put("WIN866",        "IBM866"      );
      postgresEncodingToRubyEncoding.put("WIN874",        "Windows-874" );
      postgresEncodingToRubyEncoding.put("WIN1250",       "Windows-1250");
      postgresEncodingToRubyEncoding.put("WIN1251",       "Windows-1251");
      postgresEncodingToRubyEncoding.put("WIN1252",       "Windows-1252");
      postgresEncodingToRubyEncoding.put("WIN1253",       "Windows-1253");
      postgresEncodingToRubyEncoding.put("WIN1254",       "Windows-1254");
      postgresEncodingToRubyEncoding.put("WIN1255",       "Windows-1255");
      postgresEncodingToRubyEncoding.put("WIN1256",       "Windows-1256");
      postgresEncodingToRubyEncoding.put("WIN1257",       "Windows-1257");
      postgresEncodingToRubyEncoding.put("WIN1258",       "Windows-1258");

      // set the mapping from ruby encoding to postgresql encoding
      rubyEncodingToPostgresEncoding.put("Big5",          "BIG5"          );
      rubyEncodingToPostgresEncoding.put("GB2312",        "EUC_CN"        );
      rubyEncodingToPostgresEncoding.put("EUC-JP",        "EUC_JP"        );
      rubyEncodingToPostgresEncoding.put("EUC-KR",        "EUC_KR"        );
      rubyEncodingToPostgresEncoding.put("EUC-TW",        "EUC_TW"        );
      rubyEncodingToPostgresEncoding.put("GB18030",       "GB18030"       );
      rubyEncodingToPostgresEncoding.put("GBK",           "GBK"           );
      rubyEncodingToPostgresEncoding.put("KOI8-R",        "KOI8"          );
      rubyEncodingToPostgresEncoding.put("KOI8-U",        "KOI8U"         );
      rubyEncodingToPostgresEncoding.put("ISO8859-1",    "LATIN1"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-2",    "LATIN2"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-3",    "LATIN3"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-4",    "LATIN4"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-5",    "ISO_8859_5"    );
      rubyEncodingToPostgresEncoding.put("ISO8859-6",    "ISO_8859_6"    );
      rubyEncodingToPostgresEncoding.put("ISO8859-7",    "ISO_8859_7"    );
      rubyEncodingToPostgresEncoding.put("ISO8859-8",    "ISO_8859_8"    );
      rubyEncodingToPostgresEncoding.put("ISO8859-9",    "LATIN5"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-10",   "LATIN6"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-13",   "LATIN7"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-14",   "LATIN8"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-15",   "LATIN9"        );
      rubyEncodingToPostgresEncoding.put("ISO8859-16",   "LATIN10"       );
      rubyEncodingToPostgresEncoding.put("Emacs-Mule",    "MULE_INTERNAL" );
      rubyEncodingToPostgresEncoding.put("Windows-31J",   "SJIS"          );
      rubyEncodingToPostgresEncoding.put("Windows-31J",   "SHIFT_JIS_2004");
      rubyEncodingToPostgresEncoding.put("UHC",           "CP949"         );
      rubyEncodingToPostgresEncoding.put("UTF-8",         "UTF8"          );
      rubyEncodingToPostgresEncoding.put("IBM866",        "WIN866"        );
      rubyEncodingToPostgresEncoding.put("Windows-874",   "WIN874"        );
      rubyEncodingToPostgresEncoding.put("Windows-1250",  "WIN1250"       );
      rubyEncodingToPostgresEncoding.put("Windows-1251",  "WIN1251"       );
      rubyEncodingToPostgresEncoding.put("Windows-1252",  "WIN1252"       );
      rubyEncodingToPostgresEncoding.put("Windows-1253",  "WIN1253"       );
      rubyEncodingToPostgresEncoding.put("Windows-1254",  "WIN1254"       );
      rubyEncodingToPostgresEncoding.put("Windows-1255",  "WIN1255"       );
      rubyEncodingToPostgresEncoding.put("Windows-1256",  "WIN1256"       );
      rubyEncodingToPostgresEncoding.put("Windows-1257",  "WIN1257"       );
      rubyEncodingToPostgresEncoding.put("Windows-1258",  "WIN1258"       );
    }

    public Connection(Ruby ruby, RubyClass rubyClass) {
        super(ruby, rubyClass);
    }

    public static void define(Ruby ruby, RubyModule pg, RubyModule constants) {
        RubyClass connection = pg.defineClassUnder("Connection", ruby.getObject(), CONNECTION_ALLOCATOR);

        connection.includeModule(constants);

        connection.defineAnnotatedMethods(Connection.class);

        connection.getSingletonClass().defineAlias("connect", "new");
        connection.getSingletonClass().defineAlias("open", "new");
        connection.getSingletonClass().defineAlias("setdb", "new");
        connection.getSingletonClass().defineAlias("setdblogin", "new");
    }

    /******     PG::Connection CLASS METHODS     ******/

    @JRubyMethod(meta = true)
    public static IRubyObject escape_literal_native(ThreadContext context, IRubyObject self, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod(meta = true, required = 1, argTypes = {RubyArray.class})
    public static IRubyObject escape_bytea(ThreadContext context, IRubyObject self, IRubyObject array) {
      if (LAST_CONNECTION != null)
        return LAST_CONNECTION.escape_bytea(context, array);
      return escapeBytes(context, array, context.nil, false);
    }

    @JRubyMethod(meta = true)
    public static IRubyObject unescape_bytea(ThreadContext context, IRubyObject self, IRubyObject array) {
      return unescapeBytes(context, array);
    }

    @JRubyMethod(meta = true, required = 2, argTypes = {RubyString.class, RubyString.class})
    public static IRubyObject encrypt_password(ThreadContext context, IRubyObject self, IRubyObject password, IRubyObject username) {
      if (username.isNil() || password.isNil())
        throw context.runtime.newTypeError("usernamd ane password cannot be nil");

      try {
        byte[] cryptedPassword = PostgresqlConnection.encrypt(((RubyString) username).getBytes(), ((RubyString) password).getBytes());
        return context.runtime.newString(new ByteList(cryptedPassword));
      } catch (Exception e) {
        throw context.runtime.newRuntimeError(e.getLocalizedMessage());
      }
    }

    @JRubyMethod(meta = true)
    public static IRubyObject quote_ident(ThreadContext context, IRubyObject self, IRubyObject identifier) {
      RubyString _str = (RubyString) identifier;
      return quoteIdentifier(context, identifier, _str.getByteList().getEncoding());
    }

    @JRubyMethod(rest = true, meta = true)
    public static IRubyObject connect_start(ThreadContext context, IRubyObject self, IRubyObject[] args, Block block) {
      Connection connection = new Connection(context.runtime, context.runtime.getModule("PG").getClass("Connection"));
      connection.props = parse_args(context, args);
      return connection.connectStart(context, block);
    }

    @JRubyMethod(meta = true)
    public static IRubyObject reset_last_conn(ThreadContext context, IRubyObject self) {
      LAST_CONNECTION = null;
      return context.nil;
    }

    @JRubyMethod(rest = true, meta = true)
    public static IRubyObject ping(ThreadContext context, IRubyObject self, IRubyObject[] args) {
      Properties props = Connection.parse_args(context, args);
      return context.getRuntime().newFixnum(PostgresqlConnection.ping(props).ordinal());
    }

    @JRubyMethod(meta = true)
    public static IRubyObject connectdefaults(ThreadContext context, IRubyObject self) {
        return context.nil;
    }

    /**
     * binary data is received from the jdbc driver after being unescaped
     *
     * @param context
     * @param _array
     * @return
     */
    public static IRubyObject unescapeBytes (ThreadContext context, IRubyObject _array) {
      RubyString string = (RubyString) _array;
      byte[] bytes = string.getBytes();
      if (bytes[0] == '\\' && bytes[1] == 'x') {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (int i = 2; i < bytes.length; i += 2) {
          int b = charToInt(bytes[i]) * 16 + charToInt(bytes[i + 1]);
          out.write(b);
        }
        return context.runtime.newString(new ByteList(out.toByteArray()));
      } else {
        return _array;
      }
    }

    private IRubyObject connectStart(ThreadContext context, Block block) {
      try {
        postgresqlConnection = PostgresqlConnection.connectStart(props);
        if (block.isGiven()) {
          IRubyObject value = block.yield(context, this);
          finish(context);
          return value;
        }
      } catch (Exception e) {
        // throw newPgError(context, e.getLocalizedMessage(), null, null);
      }
      return this;
    }

    private static int charToInt(byte b) {
      if (Character.isLetter(b))
        return Character.toUpperCase(b) - 'A' + 10;
      else
        return b - '0';
    }

    private static IRubyObject quoteIdentifier(ThreadContext context, IRubyObject _identifier, Encoding encoding) {
      RubyString identifier = (RubyString) _identifier;
      byte[] bytes = identifier.getBytes();
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      out.write('"');
      for (int i = 0; i < bytes.length; i++) {
        if (bytes[i] == '\0')
          break;
        if (bytes[i] == '"')
          out.write('"');
        out.write(bytes[i]);
      }
      out.write('"');
      byte[] newBytes = out.toByteArray();
      return context.runtime.newString(new ByteList(newBytes, encoding));
    }

    private static IRubyObject escapeBytes(ThreadContext context, IRubyObject _array, IRubyObject encoding, boolean standardConforminStrings) {
      RubyString array = (RubyString) _array;
      byte[] bytes = array.getBytes();

      return escapeBytes(context, bytes, encoding, standardConforminStrings);
    }

    private static IRubyObject escapeBytes(ThreadContext context, byte[] bytes, IRubyObject encoding, boolean standardConformingStrings) {
      return escapeBytes(context, bytes, 0, bytes.length, encoding, standardConformingStrings);
    }

    private static IRubyObject escapeBytes(ThreadContext context, byte[] bytes, int offset, int len,
        IRubyObject encoding, boolean standardConformingStrings) {
      if (len < 0 || offset < 0 || offset + len > bytes.length) {
        throw context.runtime.newArgumentError("Oops array offset or length isn't correct");
      }

      String prefix = "";
      if (!standardConformingStrings)
        prefix = "\\";

      ByteArrayOutputStream out = new ByteArrayOutputStream();
      PrintWriter writer = new PrintWriter(out);
      for (int i = offset; i < (offset + len); i++) {
        int byteValue= bytes[i] & 0xFF;
        if (byteValue == 39) {
          // escape the single quote
          writer.append(prefix).append("\\047");
        } else if (byteValue == 92) {
          // escape the backslash
          writer.append(prefix).append("\\134");
        } else if (byteValue >= 0 && byteValue <= 31 || byteValue >= 127 && byteValue <= 255) {
          writer.append(prefix).printf("\\%03o", byteValue);
        } else {
          // all other characters, print as themselves
          writer.write(byteValue);
        }
      }

      writer.close();
      byte[] outBytes = out.toByteArray();
      if (encoding.isNil())
        return context.runtime.newString(new ByteList(outBytes));
      return context.runtime.newString(new ByteList(outBytes, ((RubyEncoding) encoding).getEncoding()));
    }

    @SuppressWarnings("unchecked")
    private static Properties parse_args(ThreadContext context, IRubyObject[] args) {
      Properties argumentsHash = new Properties();
      if (args.length == 0)
        return argumentsHash;
      if (args.length > 7)
        throw context.getRuntime().newArgumentError("extra positional parameter");
    if (args.length != 7 && args.length != 1)
      throw context.getRuntime().newArgumentError(
          "Wrong number of arguments, see the documentation");


      if (args.length == 1) {
        // we have a string or hash
        if (args[0] instanceof RubyHash) {
          RubyHash hash = (RubyHash)args[0];

          for (Object _entry : hash.entrySet()) {
            Entry<String, Object> entry = (Entry<String, Object>) _entry;
            argumentsHash.put(PostgresHelpers.stringify(entry.getKey()), PostgresHelpers.stringify(entry.getValue()));
          }
        } else if (args[0] instanceof RubyString) {
        String[] tokens = tokenizeString(args[0].asJavaString());
        if (tokens.length % 2 != 0)
          throw context.runtime.newArgumentError("wrong connection string");
        for (int i = 0; i < tokens.length; i += 2)
          argumentsHash.put(tokens[i], tokens[i + 1]);
        } else {
          throw context.runtime.newArgumentError("Wrong type/number of arguments, see the documentation");
        }
      } else {
        // we have positional parameters
        for (int i = 0 ; i < POSITIONAL_ARGS.length ; i++) {
          if (!args[i].isNil())
          argumentsHash.put(POSITIONAL_ARGS[i], ((RubyObject) args[i]).to_s()
              .asJavaString());
        }
      }
      return argumentsHash;
    }

    private static ObjectAllocator CONNECTION_ALLOCATOR = new ObjectAllocator() {
        @Override
        public IRubyObject allocate(Ruby ruby, RubyClass rubyClass) {
            return new Connection(ruby, rubyClass);
        }
    };

    public RubyClass lookupErrorClass(ThreadContext context, String state) {
      Ruby ruby = context.getRuntime();

      if (state == null) {
        return (RubyClass) ruby.getClassFromPath("PG::UnableToSend");
      }

      state = state.toUpperCase();

      RubyHash errors = (RubyHash) ruby.getModule("PG").getConstant("ERROR_CLASSES");
      IRubyObject klass = errors.op_aref(context, ruby.newString(state));
      if (klass.isNil()) {
        klass = errors.op_aref(context, ruby.newString(state.substring(0, 2)));
      }

      if (klass.isNil()) {
        klass = ruby.getClassFromPath("PG::ServerError");
      }
      return (RubyClass) klass;
    }

    public RaiseException newPgErrorCommon(ThreadContext context, String message, String sqlstate, org.jcodings.Encoding encoding) {
      RubyClass klass = lookupErrorClass( context, sqlstate );

      if (message == null)
        message = "Unknown error";

      RubyString rubyMessage = context.runtime.newString(message);
      if (encoding != null) {
        RubyEncoding rubyEncoding = RubyEncoding.newEncoding(context.runtime, encoding);
        rubyMessage = (RubyString) rubyMessage.encode(context, rubyEncoding);
      }
      RubyObject exception = (RubyObject) klass.newInstance(context, rubyMessage, Block.NULL_BLOCK);
      exception.setInstanceVariable("@connection", this);
      return new RaiseException((RubyException) exception);
    }

    public RaiseException newPgError(ThreadContext context, String message, ResultSet result, org.jcodings.Encoding encoding) {
      String sqlstate = null;
      if (result != null) {
        sqlstate = result.getError().getFields().get(ErrorField.PG_DIAG_SQLSTATE.getCode());
      }

      RaiseException error = newPgErrorCommon(context, message, sqlstate, encoding);
      IRubyObject rubyResult = result == null ? context.nil : createResult(context, result, NULL_ARRAY, Block.NULL_BLOCK);
      error.getException().setInstanceVariable("@result", rubyResult);
      return error;
    }

    public RaiseException newPgError(ThreadContext context, Exception ex, ResultSet result, org.jcodings.Encoding encoding) {
      if (ex instanceof ClosedChannelException || ex instanceof PasswordException) {
        return newPgErrorCommon(context, ex.getLocalizedMessage(), "ConnectionBad", encoding);
      }
      return newPgErrorCommon(context, ex.getLocalizedMessage(), null, encoding);
    }

    /******     PG::Connection INSTANCE METHODS: Connection Control     ******/

    @JRubyMethod(rest = true)
    public IRubyObject initialize(ThreadContext context, IRubyObject[] args) {
        props = parse_args(context, args);
        return connectSync(context);
    }

    @JRubyMethod(alias = "reset_poll")
    public IRubyObject connect_poll(ThreadContext context) {
      try {
        ConnectionState state = postgresqlConnection.connectPoll();
        return context.runtime.newFixnum(state.ordinal());
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"finish", "close"})
    public IRubyObject finish(ThreadContext context) {
      try {
        if (postgresqlConnection.closed()) {
          throw new ClosedChannelException("connection is closed");
        }
        postgresqlConnection.close();
        return context.nil;
      } catch (java.nio.channels.ClosedChannelException e) {
        throw newPgError(context, new ClosedChannelException("connection is closed"), null, getClientEncodingAsJavaEncoding(context));
      } catch (Exception e) {
        throw newPgError(context, e, null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod
    public IRubyObject status(ThreadContext context) {
      return context.runtime.newFixnum(postgresqlConnection.status().ordinal());
    }

    @JRubyMethod(name = "finished?")
    public IRubyObject finished_p(ThreadContext context) {
        return postgresqlConnection.closed() ? context.runtime.getTrue() : context.runtime.getFalse();
    }

    @JRubyMethod
    public IRubyObject reset(ThreadContext context) {
        finish(context);
        return connectSync(context);
    }

    @JRubyMethod
    public IRubyObject reset_start(ThreadContext context) {
      finish(context);
      return connectStart(context, Block.NULL_BLOCK);
    }

    @JRubyMethod
    public IRubyObject conndefaults(ThreadContext context) {
        return context.nil;
    }

    /******     PG::Connection INSTANCE METHODS: Connection Status     ******/

    @JRubyMethod
    public IRubyObject db(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject user(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject pass(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject host(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject port(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject tty(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject options(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject transaction_status(ThreadContext context) {
      return context.runtime.newFixnum(postgresqlConnection.getTransactionStatus().getValue());
    }

    @JRubyMethod(required = 1)
    public IRubyObject parameter_status(ThreadContext context, IRubyObject arg0) {
      String name = arg0.asJavaString();
      return context.runtime.newString(postgresqlConnection.getParameterStatus(name));
    }

    @JRubyMethod
    public IRubyObject protocol_version(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject server_version(ThreadContext context) {
      return context.runtime.newFixnum(postgresqlConnection.getServerVersion());
    }

    @JRubyMethod
    public IRubyObject error_message(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject socket(ThreadContext context) {
      SelectableChannel socket = postgresqlConnection.getSocket();
      RubyIO rubyIO = RubyIO.newIO(context.runtime, socket);
      return rubyIO.fileno(context);
    }

    @JRubyMethod
    public IRubyObject backend_pid(ThreadContext context) {
      return context.runtime.newFixnum(postgresqlConnection.getBackendPid());
    }

    @JRubyMethod
    public IRubyObject connection_needs_password(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject connection_used_password(ThreadContext context) {
        return context.nil;
    }

    /******     PG::Connection INSTANCE METHODS: Command Execution     ******/

    @JRubyMethod(alias = {"query", "exec_params", "async_exec", "async_query"}, required = 1, optional = 2)
    public IRubyObject exec(ThreadContext context, IRubyObject[] args, Block block) {
        PostgresqlString query = rubyStringAsPostgresqlString(args[0]);
        ResultSet set = null;
        try {
            if (args.length == 1) {
              set = postgresqlConnection.exec(query);
            } else {

              RubyArray params = (RubyArray) args[1];

              Value [] values = new Value[params.getLength()];
              int [] oids = new int[params.getLength()];
              fillValuesAndFormat(context, params, values, oids);
              Format resultFormat = getFormat(context, args);
              set = postgresqlConnection.execQueryParams(query, values, resultFormat, oids);
            }

            if (set == null)
              return context.nil;
        } catch (PostgresqlException e) {
          throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
        } catch (Exception sqle) {
          throw newPgError(context, sqle.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
        }

        return createResult(context, set, args, block);
    }

    @JRubyMethod(required = 1, optional = 2)
    public IRubyObject async_exec(ThreadContext context, IRubyObject[] args, Block block) {
      PostgresqlString query = rubyStringAsPostgresqlString(args[0]);
      try {
        postgresqlConnection.sendQuery(query);
        // Make sure we poll for thread events in case the user call Thread.kill() or friends
        while (!postgresqlConnection.block(1000))
          context.pollThreadEvents();
        return get_result(context, block);
      } catch (IOException sqle) {
        throw newPgError(context, sqle.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    private IRubyObject connectSync(ThreadContext context) {
        // to make testing possible
        if (System.getenv("PG_TEST_SSL") != null) {
          props.setProperty("ssl", "require");
        }

        try {
            // connection = (BaseConnection)driver.connect(connectionString, props);
            postgresqlConnection = PostgresqlConnection.connectDb(props);
            // set the encoding if the default internal_encoding is set
            set_default_encoding(context);

            if (LAST_CONNECTION == null)
              LAST_CONNECTION = this;
        } catch (Exception e) {
            throw newPgError(context, e, null, null);
        }
        return context.nil;
    }

    private Format getFormat(ThreadContext context, IRubyObject [] args) {
      Format resultFormat = Format.Text;
      if (args.length == 3)
        resultFormat = ((RubyFixnum) args[2]).getLongValue() == 1 ? Format.Binary : Format.Text;
      return resultFormat;
    }

    private void fillValuesAndFormat(ThreadContext context, RubyArray params, Value[] values, int [] oids) {
      RubySymbol value_s = context.runtime.newSymbol("value");
      RubySymbol type_s = context.runtime.newSymbol("type");
      RubySymbol format_s = context.runtime.newSymbol("format");
      for (int i = 0; i < params.getLength(); i++) {
        IRubyObject param = params.entry(i);
        Format valueFormat = Format.Text;
        if (param.isNil()) {
          values[i] = new Value(null, valueFormat);
        } else if (param instanceof RubyHash) {
          RubyHash hash = (RubyHash) params.get(i);
          IRubyObject value = hash.op_aref(context, value_s);
          IRubyObject type = hash.op_aref(context, type_s);
          IRubyObject format = hash.op_aref(context, format_s);
          if (!type.isNil())
            oids[i] = (int) ((RubyFixnum) type).getLongValue();
          if (!format.isNil())
            valueFormat = ((RubyFixnum) format).getLongValue() == 1 ? Format.Binary : Format.Text;
          if (value.isNil())
            values[i] = new Value(null, valueFormat);
          else
            values[i] = new Value(((RubyString) value).getBytes(), valueFormat);
        } else {
          RubyString rubyString;
          if (param instanceof RubyString)
            rubyString = (RubyString) param;
          else
            rubyString = (RubyString) ((RubyObject) param).to_s();
          values[i] = new Value(rubyString.getBytes(), valueFormat);
        }
      }
    }

    private IRubyObject createResult(ThreadContext context, ResultSet set, IRubyObject [] args, Block block) {
      if (set == null) {
        return context.nil;
      }

      // by default we return results in text format
      boolean binary = false;
      if (args.length == 3)
        binary = ((RubyFixnum) args[2]).getLongValue() == FORMAT_BINARY;

      Result result = new Result(context.runtime, (RubyClass)context.runtime.getClassFromPath("PG::Result"), this, set, getClientEncodingAsJavaEncoding(context), binary);
      if (block.isGiven())
        return block.call(context, result);
      return result;
    }

    @JRubyMethod(required = 2, rest = true)
    public IRubyObject prepare(ThreadContext context, IRubyObject[] args) {
      try {
        PostgresqlString name = rubyStringAsPostgresqlString(args[0]);
        PostgresqlString query = rubyStringAsPostgresqlString(args[1]);
        int [] oids = null;
        if (args.length == 3) {
          RubyArray array = ((RubyArray) args[2]);
          oids = new int[array.getLength()];
          for (int i = 0; i < oids.length; i++)
            oids[i] = (int) ((RubyFixnum) array.get(i)).getLongValue();
        }
        oids = oids == null ? new int [0] : oids;
        ResultSet result = postgresqlConnection.prepare(name, query, oids);
        return createResult(context, result, NULL_ARRAY, Block.NULL_BLOCK);
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(required = 1, optional = 2)
    public IRubyObject exec_prepared(ThreadContext context, IRubyObject[] args, Block block) {
      try {
        ResultSet set = execPreparedCommon(context, args, false);
        return createResult(context, set, args, block);
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    private ResultSet execPreparedCommon(ThreadContext context, IRubyObject[] args, boolean async) throws IOException, PostgresqlException {
      PostgresqlString queryName = rubyStringAsPostgresqlString(args[0]);
      Value[] values;
      int[] oids;
      if (args.length > 1) {
        RubyArray array = (RubyArray) args[1];
        values = new Value[array.getLength()];
        oids = new int[array.getLength()];
        fillValuesAndFormat(context, array, values, oids);
      } else {
        values = new Value[0];
        oids = new int[0];
      }
      Format format = getFormat(context, args);
      if (!async)
        return postgresqlConnection.execPrepared(queryName, values, format);
      postgresqlConnection.sendExecPrepared(queryName, values, format);
      return null;
    }

    @JRubyMethod(required = 1)
    public IRubyObject describe_prepared(ThreadContext context, IRubyObject query_name) {
      try {
        PostgresqlString queryName = rubyStringAsPostgresqlString(query_name);
        ResultSet resultSet = postgresqlConnection.describePrepared(queryName);
        return createResult(context, resultSet, NULL_ARRAY, Block.NULL_BLOCK);
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(required = 1)
    public IRubyObject describe_portal(ThreadContext context, IRubyObject arg0) {
      try {
        PostgresqlString name = rubyStringAsPostgresqlString(arg0);
        ResultSet resultSet = postgresqlConnection.describePortal(name);
        return createResult(context, resultSet, NULL_ARRAY, Block.NULL_BLOCK);
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod
    public IRubyObject make_empty_pgresult(ThreadContext context, IRubyObject arg0) {
      return createResult(context, new ResultSet(), NULL_ARRAY, Block.NULL_BLOCK);
    }

    @JRubyMethod(meta = true, alias = "escape_string")
    public static IRubyObject escape(ThreadContext context, IRubyObject self, IRubyObject _str) {
      RubyString str = (RubyString) _str;
      String javaString = str.toString();
      byte[] bytes = PostgresqlConnection.escapeString(javaString, false).getBytes();
      return context.runtime.newString(new ByteList(bytes, str.getByteList().getEncoding()));
    }

    @JRubyMethod(alias = "escape_string")
    public IRubyObject escape(ThreadContext context, IRubyObject _str) {
      RubyString str = (RubyString) _str;
      String javaString = str.toString();
      byte[] bytes = PostgresqlConnection.escapeString(javaString, postgresqlConnection.getStandardConformingStrings()).getBytes();
      RubyEncoding encoding = (RubyEncoding) internal_encoding(context);
      return context.runtime.newString(new ByteList(bytes, encoding.getEncoding()));
    }

    @JRubyMethod(required = 1, argTypes = {RubyString.class} )
    public IRubyObject escape_literal_native(ThreadContext context, IRubyObject _str) {
      RubyString str = (RubyString) _str;
      byte[] bytes = str.getBytes();
      int i;
      for (i = 0; i < bytes.length && bytes[i] != '\0'; i++);
      return escapeBytes(context, bytes, 0, i, internal_encoding(context), postgresqlConnection.getStandardConformingStrings());
    }

    @JRubyMethod
    public IRubyObject escape_bytea(ThreadContext context, IRubyObject array) {
      return escapeBytes(context, array, internal_encoding(context), postgresqlConnection.getStandardConformingStrings());
    }

    @JRubyMethod
    public IRubyObject unescape_bytea(ThreadContext context, IRubyObject array) {
      return unescapeBytes(context, array);
    }

    /******     PG::Connection INSTANCE METHODS: Asynchronous Command Processing     ******/

    @JRubyMethod(rest = true)
    public IRubyObject send_query(ThreadContext context, IRubyObject[] args) {
      try {
        if (args.length == 1) {
          PostgresqlString query = rubyStringAsPostgresqlString(args[0]);
          postgresqlConnection.sendQuery(query);
        }
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
      return context.nil;
    }

    @JRubyMethod(rest = true)
    public IRubyObject send_prepare(ThreadContext context, IRubyObject[] args) {
        return context.nil;
    }

    @JRubyMethod(rest = true)
    public IRubyObject send_query_prepared(ThreadContext context, IRubyObject[] args) {
      try {
        execPreparedCommon(context, args, true);
        return context.nil;
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod
    public IRubyObject send_describe_prepared(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject send_describe_portal(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject get_result(ThreadContext context, Block block) {
      try {
        ResultSet set = postgresqlConnection.getResult();
        return createResult(context, set, NULL_ARRAY, block);
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod
    public IRubyObject consume_input(ThreadContext context) {
      try {
        postgresqlConnection.consumeInput();
        return context.nil;
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod
    public IRubyObject is_busy(ThreadContext context) {
      return context.runtime.newBoolean(postgresqlConnection.isBusy());
    }

    @JRubyMethod
    public IRubyObject set_nonblocking(ThreadContext context, IRubyObject arg0) {
      if (arg0.isTrue())
        postgresqlConnection.setNonBlocking(true);
      postgresqlConnection.setNonBlocking(false);
      return arg0;
    }

    @JRubyMethod
    public IRubyObject set_single_row_mode(ThreadContext context) {
      try {
        postgresqlConnection.setSingleRowMode();
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
      return this;
    }

    @JRubyMethod(name = {"isnonblocking", "nonblocking?"})
    public IRubyObject isnonblocking(ThreadContext context) {
      return context.runtime.newBoolean(postgresqlConnection.isNonBlocking());
    }

    @JRubyMethod
    public IRubyObject flush(ThreadContext context) {
      try {
        return context.runtime.newBoolean(postgresqlConnection.flush());
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    /******     PG::Connection INSTANCE METHODS: Cancelling Queries in Progress     ******/

    @JRubyMethod
    public IRubyObject cancel(ThreadContext context) {
      try {
        postgresqlConnection.cancel();
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
      return context.nil;
    }

    /******     PG::Connection INSTANCE METHODS: NOTIFY     ******/

    @JRubyMethod
    public IRubyObject notifies(ThreadContext context) {
      NotificationResponse notification = postgresqlConnection.notifications();
      if (notification == null)
        return context.nil;
      RubyHash hash = new RubyHash(context.runtime);

      RubySymbol relname = context.runtime.newSymbol("relname");
      RubySymbol pid = context.runtime.newSymbol("be_pid");
      RubySymbol extra = context.runtime.newSymbol("extra");

      hash.op_aset(context, relname, context.runtime.newString(notification.getCondition()));
      hash.op_aset(context, pid, context.runtime.newFixnum(notification.getPid()));
      hash.op_aset(context, extra, context.runtime.newString(notification.getPayload()));

      return hash;
    }

    /******     PG::Connection INSTANCE METHODS: COPY     ******/

    @JRubyMethod
    public IRubyObject put_copy_data(ThreadContext context, IRubyObject arg0) {
      try {
        byte[] bytes = ((RubyString) arg0).getBytes();
        ByteBuffer data = ByteBuffer.wrap(bytes);
        return context.runtime.newBoolean(postgresqlConnection.putCopyData(data));
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(rest = true)
    public IRubyObject put_copy_end(ThreadContext context, IRubyObject[] args) {
      try {
        return context.runtime.newBoolean(postgresqlConnection.putCopyDone());
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(rest = true)
    public IRubyObject get_copy_data(ThreadContext context, IRubyObject[] args) {
      try {
        boolean async = false;
        if (args.length == 1)
          async = args[0].isTrue();
        CopyData data = postgresqlConnection.getCopyData(async);
        if (data == PostgresqlConnection.COPY_DATA_NOT_READY)
          return context.runtime.getFalse();
        else if (data == null)
          return context.nil;
        ByteBuffer value = data.getValue();
        return context.runtime.newString(new ByteList(value.array(), value.arrayOffset() + value.position(), value.remaining()));
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    /******     PG::Connection INSTANCE METHODS: Control Functions     ******/

    @JRubyMethod
    public IRubyObject set_error_visibility(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject trace(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject untrace(ThreadContext context) {
        return context.nil;
    }

    /******     PG::Connection INSTANCE METHODS: Notice Processing     ******/

    @JRubyMethod
    public IRubyObject set_notice_receiver(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject set_notice_processor(ThreadContext context) {
        return context.nil;
    }

    /******     PG::Connection INSTANCE METHODS: Other    ******/

    @JRubyMethod()
    public IRubyObject transaction(ThreadContext context, Block block) {
      if (!block.isGiven())
        throw context.runtime.newArgumentError("Must supply block for PG::Connection#transaction");

      try {
        try {
          postgresqlConnection.exec(BEGIN_QUERY);
          IRubyObject yieldResult;
          if (block.arity() == Arity.NO_ARGUMENTS) {
            yieldResult = block.yieldSpecific(context);
          } else
            yieldResult = block.yieldSpecific(context, this);
          postgresqlConnection.exec(COMMIT_QUERY);
          return yieldResult;
        } catch (Exception ex) {
          postgresqlConnection.exec(ROLLBACK_QUERY);
          throw ex;
        }
      } catch (Exception e) {
        throw context.runtime.newRuntimeError(e.getLocalizedMessage());
      }
    }

    @JRubyMethod(optional = 1)
    public IRubyObject block(ThreadContext context, IRubyObject[] args) {
      try {
        if (args.length == 0)
          postgresqlConnection.block();
        else {
          RubyFloat timeout = ((RubyNumeric) args[0]).convertToFloat();
          int timeoutMs = (int) (timeout.getDoubleValue() * 1000);
          postgresqlConnection.block(timeoutMs);
        }
        return context.nil;
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"wait_for_notify", "notifies_wait"}, optional = 1)
    public IRubyObject wait_for_notify(ThreadContext context, IRubyObject[] args, Block block) {
      try {
        NotificationResponse notification = postgresqlConnection.waitForNotify();
        if (block.isGiven()) {
          if (block.arity() == Arity.NO_ARGUMENTS) return block.call(context);
          RubyString condition = context.runtime.newString(notification.getCondition());
          RubyFixnum pid = context.runtime.newFixnum(notification.getPid());
          String javaPayload = notification.getPayload();
          IRubyObject payload = javaPayload == null ? context.nil : context.runtime.newString(javaPayload);
          if (!block.arity().isFixed()) {
            return block.call(context, condition, pid, payload);
          } else if (block.arity().required() == 2) {
            return block.call(context, condition, pid);
          } else if (block.arity().required() == 3) {
            return block.call(context, condition, pid, payload);
          }
          throw context.runtime.newArgumentError("Expected a block with arity 2 or 3");
        } else {
          return context.runtime.newString(notification.getCondition());
        }
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(required = 1)
    public IRubyObject quote_ident(ThreadContext context, IRubyObject identifier) {
      return quoteIdentifier(context, identifier, ((RubyEncoding) internal_encoding(context)).getEncoding());
    }

    @JRubyMethod
    public IRubyObject get_last_result(ThreadContext context) {
      try {
        ResultSet set = postgresqlConnection.getLastResult();
        return createResult(context, set, NULL_ARRAY, Block.NULL_BLOCK);
      } catch (Exception e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    /******     PG::Connection INSTANCE METHODS: Large Object Support     ******/

    @JRubyMethod(name = {"lo_creat", "locreat"}, optional = 1)
    public IRubyObject lo_creat(ThreadContext context, IRubyObject[] args) {
      try {
        LargeObjectAPI manager = postgresqlConnection.getLargeObjectAPI();
        int oid;
        if (args.length == 1)
          oid = manager.loCreat((Integer) args[0].toJava(Integer.class));
        else
          oid = manager.loCreat(0);
        return new RubyFixnum(context.runtime, oid);
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_create failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (IOException e) {
        throw newPgError(context, "lo_create failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_create", "locreate"})
    public IRubyObject lo_create(ThreadContext context, IRubyObject arg0) {
      try {
        LargeObjectAPI manager = postgresqlConnection.getLargeObjectAPI();
        int oid = manager.loCreate((Integer) arg0.toJava(Integer.class));
        return new RubyFixnum(context.runtime, oid);
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_create failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (IOException e) {
        throw newPgError(context, "lo_create failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_import", "loimport"})
    public IRubyObject lo_import(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod(name = {"lo_export", "loexport"})
    public IRubyObject lo_export(ThreadContext context, IRubyObject arg0, IRubyObject arg1) {
        return context.nil;
    }

    @JRubyMethod(name = {"lo_open", "loopen"}, required = 1, optional = 1)
    public IRubyObject lo_open(ThreadContext context, IRubyObject [] args) {
      try {
        int fd;
        long oidLong = (Long) args[0].toJava(Long.class);
        if (args.length == 1)
          fd = postgresqlConnection.getLargeObjectAPI().loOpen((int) oidLong);
        else
          fd = postgresqlConnection.getLargeObjectAPI().loOpen((int) oidLong, (Integer) args[1].toJava(Integer.class));

        return context.runtime.newFixnum(fd);
      } catch (IOException e) {
        throw newPgError(context, "lo_open failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_open failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_write", "lowrite"}, required = 2, argTypes = {RubyFixnum.class, RubyString.class})
    public IRubyObject lo_write(ThreadContext context, IRubyObject object, IRubyObject buffer) {
      try {
        long fd = ((RubyFixnum) object).getLongValue();
        RubyString bufferString = (RubyString) buffer;
        int count = postgresqlConnection.getLargeObjectAPI().loWrite((int) fd, bufferString.getBytes());
        return context.runtime.newFixnum(count);
      } catch (IOException e) {
        throw newPgError(context, "lo_write failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_write failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_read", "loread"}, required = 2, argTypes = {RubyFixnum.class, RubyFixnum.class})
    public IRubyObject lo_read(ThreadContext context, IRubyObject arg0, IRubyObject arg1) {
      try {
        int fd = (int) ((RubyFixnum) arg0).getLongValue();
        int count = (int) ((RubyFixnum) arg1).getLongValue();
        byte[] b = postgresqlConnection.getLargeObjectAPI().loRead(fd, count);
        if (b.length == 0)
          return context.nil;
        return context.runtime.newString(new ByteList(b));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_read failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (IOException e) {
        throw newPgError(context, "lo_read failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_lseek", "lolseek", "lo_seek", "loseek"}, required = 3,
        argTypes = {RubyFixnum.class, RubyFixnum.class, RubyFixnum.class})
    public IRubyObject lo_lseek(ThreadContext context, IRubyObject _fd, IRubyObject _offset, IRubyObject _whence) {
      try {
        int offset = (int) ((RubyFixnum) _offset).getLongValue();
        int fd = (int) ((RubyFixnum) _fd).getLongValue();
        int whence = (int) ((RubyFixnum) _whence).getLongValue();
        int where = postgresqlConnection.getLargeObjectAPI().loSeek(fd, offset, whence);
        return new RubyFixnum(context.runtime, where);
      } catch (IOException e) {
        throw newPgError(context, "lo_lseek failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_lseek failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_tell", "lotell"}, required = 1, argTypes = {RubyFixnum.class})
    public IRubyObject lo_tell(ThreadContext context, IRubyObject _fd) {
      try {
        int fd = (int) ((RubyFixnum) _fd).getLongValue();
        int where = postgresqlConnection.getLargeObjectAPI().loTell(fd);
        return context.runtime.newFixnum(where);
      } catch (IOException e) {
        throw newPgError(context, "lo_tell failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_tell failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_truncate", "lotruncate"}, required = 2, argTypes = {RubyFixnum.class, RubyFixnum.class})
    public IRubyObject lo_truncate(ThreadContext context, IRubyObject _fd, IRubyObject _len) {
      try {
        int fd = (int) ((RubyFixnum) _fd).getLongValue();
        int len = (int) ((RubyFixnum) _len).getLongValue();
        int value = postgresqlConnection.getLargeObjectAPI().loTruncate(fd, len);
        return context.runtime.newFixnum(value);
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_tell failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      } catch (IOException e) {
        throw newPgError(context, "lo_tell failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_close", "loclose"}, required = 1, argTypes = {RubyFixnum.class})
    public IRubyObject lo_close(ThreadContext context, IRubyObject _fd) {
      try {
        int fd = (int) ((RubyFixnum) _fd).getLongValue();
        int value = postgresqlConnection.getLargeObjectAPI().loClose(fd);
        return context.runtime.newFixnum(value);
      } catch (IOException e) {
        throw newPgError(context, "lo_close failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_close failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod(name = {"lo_unlink", "lounlink"}, required = 1, argTypes = {RubyFixnum.class})
    public IRubyObject lo_unlink(ThreadContext context, IRubyObject _fd) {
      try {
        int fd = (int) ((RubyFixnum) _fd).getLongValue();
        int value = postgresqlConnection.getLargeObjectAPI().loUnlink(fd);
        return context.runtime.newFixnum(value);
      } catch (IOException e) {
        throw newPgError(context, "lo_unlink failed: " + e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, "lo_unlink failed: " + e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    /******     M17N     ******/

    @JRubyMethod
    public IRubyObject get_client_encoding(ThreadContext context) {
      return context.runtime.newString(postgresqlConnection.getClientEncoding());
    }

    @JRubyMethod(required = 1, alias = {"client_encoding="})
    public IRubyObject set_client_encoding(ThreadContext context, IRubyObject encoding) {
      return setClientEncodingCommon(context, encoding.asJavaString());
    }

    @JRubyMethod
    public IRubyObject internal_encoding(ThreadContext context) {
      if (postgresqlConnection == null)
        return context.nil;

      String encoding = postgresqlConnection.getClientEncoding();
      return findEncoding(context, postgresEncodingToRubyEncoding.get(encoding));
    }

    @JRubyMethod(name = "internal_encoding=")
    public IRubyObject set_internal_encoding(ThreadContext context, IRubyObject encoding) {
      try {
        String postgresEncoding;
        if (encoding instanceof RubyString) {
          postgresEncoding = encoding.asJavaString().toUpperCase();
        } else if (encoding instanceof RubyEncoding) {
          postgresEncoding = ((RubyEncoding) encoding).to_s(context).asJavaString();
        } else {
          postgresEncoding = "SQL_ASCII";
        }
        if (rubyEncodingToPostgresEncoding.containsKey(postgresEncoding))
            postgresEncoding = rubyEncodingToPostgresEncoding.get(postgresEncoding);
        else
            postgresEncoding = "SQL_ASCII";
        postgresqlConnection.setClientEncoding(postgresEncoding);
        return context.nil;
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), getClientEncodingAsJavaEncoding(context));
      }
    }

    @JRubyMethod
    public IRubyObject external_encoding(ThreadContext context) {
      String encoding = postgresqlConnection.getServerEncoding();
      return findEncoding(context, postgresEncodingToRubyEncoding.get(encoding));
    }

    @JRubyMethod
    public IRubyObject set_default_encoding(ThreadContext context) {
      IRubyObject _internal_encoding = RubyEncoding.getDefaultInternal(this);
      if (_internal_encoding.isNil())
        return context.nil;
      return set_internal_encoding(context, _internal_encoding);
    }

    private static String[] tokenizeString(String asJavaString) {
      List<String> tokens = new ArrayList<String>();
      StringBuffer currentToken = new StringBuffer();
      boolean insideSingleQuote = false;
      boolean escapeNextCharacter = false;
      for (int i = 0; i < asJavaString.length(); i++) {
        char currentChar = asJavaString.charAt(i);

        // finish the current token and append it if:
        //   - we just hit an equal sign or a space and we're not inside single quotes
        //   - we just hit a single quote and we're inside a token
        //   - we're at the end of the input string
        if ((currentChar == '=' || Character.isWhitespace(currentChar)) && !insideSingleQuote ||
            (currentChar == '\'' && !escapeNextCharacter && insideSingleQuote)) {
          if (insideSingleQuote)
            insideSingleQuote = false;
          tokens.add(currentToken.toString());
          currentToken = new StringBuffer();
          // get rid of all the whitespaces and equal sign that follow
          i = consumeWhiteSpaceAndEqual(asJavaString, i);
        } else if (currentChar == '\\' && !escapeNextCharacter) {
          escapeNextCharacter = true;
        } else if (currentChar == '\'' && !escapeNextCharacter) {
          // don't add the last single quote. we just started a new token
          // surrounded by single quotes
          insideSingleQuote = true;
        } else {
          escapeNextCharacter = false;
          currentToken.append(currentChar);
        }
      }
      if (currentToken.length() != 0)
        tokens.add(currentToken.toString());
      return tokens.toArray(new String[tokens.size()]);
    }

    private static int consumeWhiteSpaceAndEqual(String string, int currentIndex) {
      for (int i = currentIndex + 1; i < string.length(); i++) {
        char currentCharacter = string.charAt(i);
        if (!Character.isWhitespace(currentCharacter) && currentCharacter != '=')
          return i - 1;
      }
      return string.length();
    }

    private PostgresqlString rubyStringAsPostgresqlString(IRubyObject str) {
      return new PostgresqlString(((RubyString) str).getBytes());
    }

    private IRubyObject setClientEncodingCommon(ThreadContext context, String encoding) {
      try {
        postgresqlConnection.setClientEncoding(encoding);
        return context.nil;
      } catch (IOException e) {
        throw newPgError(context, e.getLocalizedMessage(), null, this.getClientEncodingAsJavaEncoding(context));
      } catch (PostgresqlException e) {
        throw newPgError(context, e.getLocalizedMessage(), e.getResultSet(), this.getClientEncodingAsJavaEncoding(context));
      }
    }

    private Encoding getClientEncodingAsJavaEncoding(ThreadContext context) {
      IRubyObject encoding = internal_encoding(context);
      if (encoding.isNil())
        return null;
      return ((RubyEncoding) encoding).getEncoding();
    }

    private IRubyObject findEncoding(ThreadContext context, String encodingName) {
      IRubyObject rubyEncodingName = encodingName == null ? context.nil : context.runtime.newString(encodingName);
      return findEncoding(context, rubyEncodingName);
    }

    private IRubyObject findEncoding(ThreadContext context, IRubyObject encodingName) {
      IRubyObject encoding = context.nil;
      try {
        if (!encodingName.isNil())
          encoding = context.runtime.getClass("Encoding").callMethod("find", encodingName);
      } catch (RuntimeException e) {
      }
      if (encoding.isNil())
        encoding = context.runtime.getClass("Encoding").getConstant("ASCII_8BIT");
      return encoding;
    }
}
