package org.jruby.pg.internal;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.jruby.pg.internal.messages.DataRow;
import org.jruby.pg.internal.messages.ErrorResponse;
import org.jruby.pg.internal.messages.ParameterDescription;
import org.jruby.pg.internal.messages.RowDescription;

public class ResultSet {
  public enum ResultStatus {
    PGRES_EMPTY_QUERY,
    PGRES_COMMAND_OK,
    PGRES_TUPLES_OK,
    PGRES_COPY_OUT,
    PGRES_COPY_IN,
    PGRES_BAD_RESPONSE,
    PGRES_NONFATAL_ERROR,
    PGRES_FATAL_ERROR,
    PGRES_SINGLE_TUPLE,
    PGRES_COPY_BOTH;
  }

  private ResultStatus status;
  private RowDescription descrption;
  private ParameterDescription parameterDescription;
  private final List<DataRow> rows = new ArrayList<DataRow>();
  private int affectedRows;
  private ErrorResponse error;

  public ResultSet() {
    this.status = ResultStatus.PGRES_COMMAND_OK;
  }

  public void setDescription(RowDescription descrption) {
    this.descrption = descrption;
  }

  public void appendRow(DataRow row) {
    rows.add(row);
  }

  public void setErrorResponse(ErrorResponse error) {
    this.error = error;
  }

  public List<DataRow> getRows() {
    return Collections.unmodifiableList(rows);
  }

  public RowDescription getDescription() {
    return descrption;
  }

  public ErrorResponse getError() {
    return error;
  }

  public void setStatus(ResultStatus status) {
    this.status = status;
  }

  public ResultStatus getStatus() {
    if (status != null)
      return status;
    if (error != null) {
      if (error.isFatal())
        return ResultStatus.PGRES_FATAL_ERROR;
      else
        return ResultStatus.PGRES_NONFATAL_ERROR;
    }
    if (descrption == null || descrption.getColumns().length == 0)
      return ResultStatus.PGRES_EMPTY_QUERY;
    return ResultStatus.PGRES_TUPLES_OK;
  }

  public ParameterDescription getParameterDescription() {
    return parameterDescription;
  }

  public void setParameterDescription(ParameterDescription parameterDescription) {
    this.parameterDescription = parameterDescription;
  }

  public int getAffectedRows() {
	return affectedRows;
}

public void setAffectedRows(int affectedRows) {
	this.affectedRows = affectedRows;
}

public boolean hasError() {
    return error != null;
  }
}
