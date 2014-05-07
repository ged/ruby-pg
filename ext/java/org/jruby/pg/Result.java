package org.jruby.pg;

import java.nio.ByteBuffer;
import java.util.List;

import org.jcodings.Encoding;
import org.jruby.Ruby;
import org.jruby.RubyArray;
import org.jruby.RubyClass;
import org.jruby.RubyFixnum;
import org.jruby.RubyHash;
import org.jruby.RubyModule;
import org.jruby.RubyObject;
import org.jruby.RubyString;
import org.jruby.anno.JRubyMethod;
import org.jruby.pg.internal.ResultSet;
import org.jruby.pg.internal.messages.Column;
import org.jruby.pg.internal.messages.DataRow;
import org.jruby.pg.internal.messages.ErrorResponse;
import org.jruby.pg.internal.messages.Format;
import org.jruby.pg.internal.messages.RowDescription;
import org.jruby.runtime.Block;
import org.jruby.runtime.ObjectAllocator;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.ByteList;

public class Result extends RubyObject {
    protected final ResultSet jdbcResultSet;
    protected final Encoding encoding;
    protected final boolean binary; // return results in binary format
    private final Connection connection;

    public Result(Ruby ruby, RubyClass rubyClass, Connection connection, ResultSet resultSet, Encoding encoding, boolean binary) {
        super(ruby, rubyClass);
        this.connection = connection;

        this.jdbcResultSet = resultSet;
        this.encoding = encoding;
        this.binary = binary;
    }

    public static void define(Ruby ruby, RubyModule pg, RubyModule constants) {
        RubyClass result = pg.defineClassUnder("Result", ruby.getObject(), ObjectAllocator.NOT_ALLOCATABLE_ALLOCATOR);

        result.includeModule(ruby.getEnumerable());
        result.includeModule(constants);

        pg.defineClassUnder("LargeObjectFd", ruby.getObject(), ObjectAllocator.NOT_ALLOCATABLE_ALLOCATOR);

        result.defineAnnotatedMethods(Result.class);
    }

    /******     PG::Result INSTANCE METHODS: libpq     ******/

    @JRubyMethod
    public IRubyObject result_status(ThreadContext context) {
      return context.runtime.newFixnum(jdbcResultSet.getStatus().ordinal());
    }

    @JRubyMethod
    public IRubyObject res_status(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod(name = {"error_message", "result_error_message"})
    public IRubyObject error_message(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod(name = {"error_field", "result_error_field"})
    public IRubyObject error_field(ThreadContext context, IRubyObject arg0) {
      byte errorCode = (byte) ((RubyFixnum) arg0).getLongValue();
      ErrorResponse error = jdbcResultSet.getError();
      if (error == null)
        return context.nil;
      String field = error.getFields().get(errorCode);
      return field == null ? context.nil : context.runtime.newString(field);
    }

    @JRubyMethod
    public IRubyObject clear(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod(name = {"check", "check_result"})
    public IRubyObject check(ThreadContext context) {
      if (jdbcResultSet.hasError())
        throw connection.newPgError(context, jdbcResultSet.getError().getErrorMesssage(), null, encoding);
      return context.nil;
    }

    @JRubyMethod(name = {"ntuples", "num_tuples"})
    public IRubyObject ntuples(ThreadContext context) {
      return context.runtime.newFixnum(jdbcResultSet.getRows().size());
    }

    @JRubyMethod(name = {"nfields", "num_fields"})
    public IRubyObject nfields(ThreadContext context) {
      if (jdbcResultSet == null)
        throw context.runtime.newTypeError("foo");
      if (jdbcResultSet.getDescription() == null)
        return context.runtime.newFixnum(0);
      return context.runtime.newFixnum(jdbcResultSet.getDescription().getColumns().length);
    }

    @JRubyMethod
    public IRubyObject fname(ThreadContext context, IRubyObject _columnIndex) {
      int columnIndex = (int) ((RubyFixnum) _columnIndex).getLongValue();
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      if (columnIndex >= columns.length || columnIndex < 0)
        throw context.runtime.newArgumentError("invalid field number " + columnIndex);

      return context.runtime.newString(columns[columnIndex].getName());
    }

    @JRubyMethod
    public IRubyObject fnumber(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod(required = 1)
    public IRubyObject ftable(ThreadContext context, IRubyObject _columnIndex) {
      int columnIndex = (int) ((RubyFixnum) _columnIndex).getLongValue();
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      if (columnIndex >= columns.length || columnIndex < 0)
        throw context.runtime.newArgumentError("column " + columnIndex + " is out of range");

      int oid = columns[columnIndex].getTableOid();
      return context.runtime.newFixnum(oid);
    }

    @JRubyMethod(required = 1)
    public IRubyObject ftablecol(ThreadContext context, IRubyObject _columnIndex) {
      int columnIndex = (int) ((RubyFixnum) _columnIndex).getLongValue();
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      if (columnIndex >= columns.length || columnIndex < 0)
        throw context.runtime.newArgumentError("column " + columnIndex + " is out of range");

      int tableIndex = columns[columnIndex].getTableIndex();
      return context.runtime.newFixnum(tableIndex);
    }

    @JRubyMethod
    public IRubyObject fformat(ThreadContext context, IRubyObject arg0) {
      int index = (int) ((RubyFixnum) arg0).getLongValue();
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      if (index >= columns.length || index < 0)
        throw context.runtime.newArgumentError("column number " + index + " is out of range");
      return context.runtime.newFixnum(columns[index].getFormat());
    }

    @JRubyMethod(required = 1, argTypes = {RubyFixnum.class})
    public IRubyObject ftype(ThreadContext context, IRubyObject fieldNumber) {
      RowDescription description = jdbcResultSet.getDescription();
      int field = (int) ((RubyFixnum) fieldNumber).getLongValue();
      if (field >= description.getColumns().length) {
        throw context.runtime.newIndexError("field " + field + " is out of range");
      }
      return context.runtime.newFixnum(description.getColumns()[field].getOid());
    }

    @JRubyMethod
    public IRubyObject fmod(ThreadContext context, IRubyObject arg0) {
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      int index = (int) ((RubyFixnum) arg0).getLongValue();
      if (index < 0 || index >= columns.length)
        throw context.runtime.newArgumentError("column number " + index + " is out of range");
      return context.runtime.newFixnum(columns[index].getTypmod());
    }

    @JRubyMethod
    public IRubyObject fsize(ThreadContext context, IRubyObject arg0) {
        return context.nil;
    }

    @JRubyMethod(required = 2, argTypes = {RubyFixnum.class, RubyFixnum.class})
    public IRubyObject getvalue(ThreadContext context, IRubyObject _row, IRubyObject _column) {
      int row = (int) ((RubyFixnum) _row).getLongValue();
      int column = (int) ((RubyFixnum) _column).getLongValue();

      List<DataRow> rows = jdbcResultSet.getRows();
      if (row >= rows.size()) {
        throw context.runtime.newIndexError("row " + row + " is out of range");
      }
      DataRow dataRow = rows.get(row);
      ByteBuffer[] columns = dataRow.getValues();
      if (column >= columns.length) {
        throw context.runtime.newIndexError("column " + column + " is out of range");
      }
      return valueAsString(context, row, column);
    }

    @JRubyMethod
    public IRubyObject getisnul(ThreadContext context, IRubyObject arg0, IRubyObject arg1) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject getlength(ThreadContext context, IRubyObject arg0, IRubyObject arg1) {
        return context.nil;
    }

    @JRubyMethod
    public IRubyObject nparams(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod(required = 1)
    public IRubyObject paramtype(ThreadContext context, IRubyObject arg0) {
      int index = (int) ((RubyFixnum) arg0).getLongValue();
      if (jdbcResultSet.getParameterDescription() == null)
        throw connection.newPgError(context, "Parameter desciption not available", null, encoding);
      int[] oids = jdbcResultSet.getParameterDescription().getOids();
      if (index >= oids.length)
        throw context.runtime.newIndexError("index " + index + " is out of range");
      return context.runtime.newFixnum(oids[index]);
    }

    @JRubyMethod
    public IRubyObject cmd_status(ThreadContext context) {
        return context.nil;
    }

    @JRubyMethod(name = {"cmd_tuples", "cmdtuples"})
    public IRubyObject cmd_tuples(ThreadContext context) {
    	return context.runtime.newFixnum(jdbcResultSet.getAffectedRows());
    }

    @JRubyMethod
    public IRubyObject old_value(ThreadContext context) {
        return context.nil;
    }

    /******     PG::Result INSTANCE METHODS: other     ******/

    @JRubyMethod
    public IRubyObject values(ThreadContext context) {
      int len = jdbcResultSet.getRows().size();
      RubyArray array = context.runtime.newArray();
      for (int i = 0; i < len; i++)
        array.append(rowToArray(context, i));
      return array;
    }

    @JRubyMethod(name = "[]", required = 1)
    public IRubyObject op_aref(ThreadContext context, IRubyObject row) {
      int index = (int) ((RubyFixnum) row).getLongValue();
      return rowToHash(context, index);
    }

    @JRubyMethod
    public IRubyObject each(ThreadContext context, Block block) {
      for (int i = 0; i < jdbcResultSet.getRows().size(); i++)
        block.yield(context, rowToHash(context, i));
      return context.nil;
    }

    @JRubyMethod
    public IRubyObject each_row(ThreadContext context, Block block) {
      for (int i = 0; i < jdbcResultSet.getRows().size(); i++)
        block.yield(context, rowToArray(context, i));
      return context.nil;
    }

    @JRubyMethod
    public IRubyObject fields(ThreadContext context) {
      RowDescription description = jdbcResultSet.getDescription();
      if (description == null)
        return context.runtime.newArray();
      Column[] columns = description.getColumns();
      RubyArray fields = context.runtime.newArray(columns.length);
      for (int i = 0; i < columns.length; i++)
        fields.append(context.runtime.newString(columns[i].getName()));
      return fields;
    }

    @JRubyMethod(required = 1, argTypes = {RubyFixnum.class})
    public IRubyObject column_values(ThreadContext context, IRubyObject index) {
      if (!(index instanceof RubyFixnum))
        throw context.runtime.newTypeError("argument should be a Fixnum");

      int column = (int) ((RubyFixnum) index).getLongValue();

      List<DataRow> rows = jdbcResultSet.getRows();
      if (rows.size() > 0 && column >= rows.get(0).getValues().length) {
        throw context.runtime.newIndexError("column " + column + " is out of range");
      }
      RubyArray array = context.runtime.newArray();
      for (int i = 0; i < rows.size(); i++) {
        array.append(valueAsString(context, i, column));
      }
      return array;
    }

    @JRubyMethod(required = 1, argTypes = {RubyString.class})
    public IRubyObject field_values(ThreadContext context, IRubyObject name) {
      if (!(name instanceof RubyString)) {
        throw context.runtime.newTypeError("argument isn't a string");
      }

      String fieldName = ((RubyString) name).asJavaString();
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      for (int j = 0; j < columns.length; j++) {
        if (columns[j].getName().equals(fieldName)) {
          RubyArray array = context.runtime.newArray();
          for (int i = 0; i < jdbcResultSet.getRows().size(); i++)
            array.append(valueAsString(context, i, j));
          return array;
        }
      }
      throw context.runtime.newIndexError("Unknown column " + fieldName);
    }

    private RubyArray rowToArray(ThreadContext context, int rowIndex) {
      List<DataRow> rows = jdbcResultSet.getRows();
      if (rowIndex >= rows.size())
        throw context.runtime.newIndexError("row " + rowIndex);

      RubyArray array = context.runtime.newArray();

      for (int i = 0; i < rows.get(rowIndex).getValues().length; i++) {
        IRubyObject value = valueAsString(context, rowIndex, i);
        array.append(value);
      }
      return array;
    }

    private RubyHash rowToHash(ThreadContext context, int rowIndex) {
      List<DataRow> rows = jdbcResultSet.getRows();
      Column[] columns = jdbcResultSet.getDescription().getColumns();
      if (rowIndex < 0 || rowIndex >= rows.size())
        throw context.runtime.newIndexError("row " + rowIndex + " is out of range");

      RubyHash hash = new RubyHash(context.runtime);

      for (int i = 0; i < rows.get(rowIndex).getValues().length; i++) {
        IRubyObject name = context.runtime.newString(columns[i].getName());
        IRubyObject value = valueAsString(context, rowIndex, i);
        hash.op_aset(context, name, value);
      }
      return hash;
    }

    private IRubyObject valueAsString(ThreadContext context, int row, int column) {
      ByteBuffer[] values = jdbcResultSet.getRows().get(row).getValues();
      if (values[column] == null) {
        return context.nil;
      }
      byte[] bytes = values[column].array();
      int index = values[column].arrayOffset() + values[column].position();
      int len = values[column].remaining();

      if (isBinary(column))
        return context.runtime.newString(new ByteList(bytes, index, len));
      else
        return context.runtime.newString(new ByteList(bytes, index, len, encoding, false));
    }

    private boolean isBinary(int column) {
      int format = jdbcResultSet.getDescription().getColumns()[column].getFormat();
      return Format.isBinary(format);
    }
}
