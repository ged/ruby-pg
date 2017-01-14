/*
 * pg_row_coder.c - PG::Coder class extension
 *
 */

#include "pg.h"

VALUE rb_cPG_RowCoder;
VALUE rb_cPG_RowEncoder;
VALUE rb_cPG_RowDecoder;

typedef struct {
	t_pg_coder comp;
	VALUE typemap;
} t_pg_rowcoder;


static void
pg_rowcoder_mark( t_pg_rowcoder *this )
{
	rb_gc_mark(this->typemap);
}

static VALUE
pg_rowcoder_encoder_allocate( VALUE klass )
{
	t_pg_rowcoder *this;
	VALUE self = Data_Make_Struct( klass, t_pg_rowcoder, pg_rowcoder_mark, -1, this );
	pg_coder_init_encoder( self );
	this->typemap = pg_typemap_all_strings;
	return self;
}

static VALUE
pg_rowcoder_decoder_allocate( VALUE klass )
{
	t_pg_rowcoder *this;
	VALUE self = Data_Make_Struct( klass, t_pg_rowcoder, pg_rowcoder_mark, -1, this );
	pg_coder_init_decoder( self );
	this->typemap = pg_typemap_all_strings;
	return self;
}

/*
 * call-seq:
 *    coder.type_map = map
 *
 * +map+ must be a kind of PG::TypeMap .
 *
 * Defaults to a PG::TypeMapAllStrings , so that PG::TextEncoder::String respectively
 * PG::TextDecoder::String is used for encoding/decoding of all columns.
 *
 */
static VALUE
pg_rowcoder_type_map_set(VALUE self, VALUE type_map)
{
	t_pg_rowcoder *this = DATA_PTR( self );

	if ( !rb_obj_is_kind_of(type_map, rb_cTypeMap) ){
		rb_raise( rb_eTypeError, "wrong elements type %s (expected some kind of PG::TypeMap)",
				rb_obj_classname( type_map ) );
	}
	this->typemap = type_map;

	return type_map;
}

/*
 * call-seq:
 *    coder.type_map -> PG::TypeMap
 *
 */
static VALUE
pg_rowcoder_type_map_get(VALUE self)
{
	t_pg_rowcoder *this = DATA_PTR( self );

	return this->typemap;
}


/*
 * Document-class: PG::TextEncoder::RowRow < PG::RowEncoder
 *
 * This class encodes one row of arbitrary columns for transmission as COPY data in text format.
 * See the {COPY command}[http://www.postgresql.org/docs/current/static/sql-copy.html]
 * for description of the format.
 *
 * It is intended to be used in conjunction with PG::Connection#put_copy_data .
 *
 * The columns are expected as Array of values. The single values are encoded as defined
 * in the assigned #type_map. If no type_map was assigned, all values are converted to
 * strings by PG::TextEncoder::String.
 *
 * Example with default type map ( TypeMapAllStrings ):
 *   conn.exec "create table my_table (a text,b int,c bool)"
 *   enco = PG::TextEncoder::RowRow.new
 *   conn.copy_data "COPY my_table FROM STDIN", enco do
 *     conn.put_copy_data ["astring", 7, false]
 *     conn.put_copy_data ["string2", 42, true]
 *   end
 * This creates +my_table+ and inserts two rows.
 *
 * It is possible to manually assign a type encoder for each column per PG::TypeMapByColumn,
 * or to make use of PG::BasicTypeMapBasedOnResult to assign them based on the table OIDs.
 *
 * See also PG::TextDecoder::RowRow for the decoding direction with
 * PG::Connection#get_copy_data .
 */
static int
pg_text_enc_row(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate, int enc_idx)
{
	t_pg_rowcoder *this = (t_pg_rowcoder *)conv;
	t_pg_coder_enc_func enc_func;
	static t_pg_coder *p_elem_coder;
	int i;
	t_typemap *p_typemap;
	char *current_out;
	char *end_capa_ptr;

	p_typemap = DATA_PTR( this->typemap );
	p_typemap->funcs.fit_to_query( this->typemap, value );

	/* Allocate a new string with embedded capacity and realloc exponential when needed. */
	PG_RB_STR_NEW( *intermediate, current_out, end_capa_ptr );
	PG_ENCODING_SET_NOCHECK(*intermediate, enc_idx);
	PG_RB_STR_ENSURE_CAPA( *intermediate, 1, current_out, end_capa_ptr );
	*current_out++ = '(';

	for( i=0; i<RARRAY_LEN(value); i++){
		char *ptr1;
		char *ptr2;
		int strlen;
		int backslashs;
		VALUE subint;
		VALUE entry;

		entry = rb_ary_entry(value, i);

		if( i > 0 ){
			PG_RB_STR_ENSURE_CAPA( *intermediate, 1, current_out, end_capa_ptr );
			*current_out++ = ',';
		}

		switch(TYPE(entry)){
			case T_NIL:
				/* emit nothing... */
				break;
			default:
				p_elem_coder = p_typemap->funcs.typecast_query_param(p_typemap, entry, i);
				enc_func = pg_coder_enc_func(p_elem_coder);

				/* 1st pass for retiving the required memory space */
				strlen = enc_func(p_elem_coder, entry, NULL, &subint, enc_idx);

				if( strlen == -1 ){
					/* we can directly use String value in subint */
					strlen = RSTRING_LEN(subint);

					/* size of string assuming the worst case, that every character must be escaped. */
					PG_RB_STR_ENSURE_CAPA( *intermediate, strlen * 2 + 2, current_out, end_capa_ptr );

					*current_out++ = '"';
					/* Row string from subint with backslash escaping */
					for(ptr1 = RSTRING_PTR(subint); ptr1 < RSTRING_PTR(subint) + strlen; ptr1++) {
						if (*ptr1 == '"' || *ptr1 == '\\') {
							*current_out++ = *ptr1;
						}
						*current_out++ = *ptr1;
					}
					*current_out++ = '"';
				} else {
					/* 2nd pass for writing the data to prepared buffer */
					/* size of string assuming the worst case, that every character must be escaped. */
					PG_RB_STR_ENSURE_CAPA( *intermediate, strlen * 2 + 2, current_out, end_capa_ptr );

					*current_out++ = '"';
					/* Place the unescaped string at current output position. */
					strlen = enc_func(p_elem_coder, entry, current_out, &subint, enc_idx);

					ptr1 = current_out;
					ptr2 = current_out + strlen;

					/* count required backlashs */
					for(backslashs = 0; ptr1 != ptr2; ptr1++) {
						/* Escape backslash itself, newline, carriage return, and the current delimiter character. */
						if(*ptr1 == '"' || *ptr1 == '\\'){
							backslashs++;
						}
					}

					ptr1 = current_out + strlen;
					ptr2 = current_out + strlen + backslashs;
					current_out = ptr2;

					/* Then store the escaped string on the final position, walking
					 * right to left, until all backslashs are placed. */
					while( ptr1 != ptr2 ) {
						*--ptr2 = *--ptr1;
						if(*ptr1 == '"' || *ptr1 == '\\'){
							*--ptr2 = *ptr1;
						}
					}
					*current_out++ = '"';
				}
		}
	}
	PG_RB_STR_ENSURE_CAPA( *intermediate, 1, current_out, end_capa_ptr );
	*current_out++ = ')';

	rb_str_set_len( *intermediate, current_out - RSTRING_PTR(*intermediate) );

	return -1;
}

/*
 * row_isspace() --- a non-locale-dependent isspace()
 *
 * We used to use isspace() for parsing array values, but that has
 * undesirable results: an array value might be silently interpreted
 * differently depending on the locale setting.  Now we just hard-wire
 * the traditional ASCII definition of isspace().
 */
static int
row_isspace(char ch)
{
	if (ch == ' ' ||
		ch == '\t' ||
		ch == '\n' ||
		ch == '\r' ||
		ch == '\v' ||
		ch == '\f')
		return 1;
	return 0;
}

/*
 * Document-class: PG::TextDecoder::RowRow < PG::RowDecoder
 *
 * This class decodes one row of arbitrary columns received as COPY data in text format.
 * See the {COPY command}[http://www.postgresql.org/docs/current/static/sql-copy.html]
 * for description of the format.
 *
 * It is intended to be used in conjunction with PG::Connection#get_copy_data .
 *
 * The columns are retrieved as Array of values. The single values are decoded as defined
 * in the assigned #type_map. If no type_map was assigned, all values are converted to
 * strings by PG::TextDecoder::String.
 *
 * Example with default type map ( TypeMapAllStrings ):
 *   conn.exec("CREATE TABLE my_table AS VALUES('astring', 7, FALSE), ('string2', 42, TRUE) ")
 *
 *   deco = PG::TextDecoder::RowRow.new
 *   conn.copy_data "COPY my_table TO STDOUT", deco do
 *     while row=conn.get_copy_data
 *       p row
 *     end
 *   end
 * This prints all rows of +my_table+ :
 *   ["astring", "7", "f"]
 *   ["string2", "42", "t"]
 *
 * Example with column based type map:
 *   tm = PG::TypeMapByColumn.new( [
 *     PG::TextDecoder::String.new,
 *     PG::TextDecoder::Integer.new,
 *     PG::TextDecoder::Boolean.new] )
 *   deco = PG::TextDecoder::RowRow.new( type_map: tm )
 *   conn.copy_data "COPY my_table TO STDOUT", deco do
 *     while row=conn.get_copy_data
 *       p row
 *     end
 *   end
 * This prints the rows with type casted columns:
 *   ["astring", 7, false]
 *   ["string2", 42, true]
 *
 * Instead of manually assigning a type decoder for each column, PG::BasicTypeMapForResults
 * can be used to assign them based on the table OIDs.
 *
 * See also PG::TextEncoder::RowRow for the encoding direction with
 * PG::Connection#put_copy_data .
 */
/*
 * Parse the current line into separate attributes (fields),
 * performing de-escaping as needed.
 *
 * All fields are gathered into a ruby Array. The de-escaped field data is written
 * into to a ruby String. This object is reused for non string columns.
 * For String columns the field value is directly used as return value and no
 * reuse of the memory is done.
 *
 * The parser is thankfully borrowed from the PostgreSQL sources:
 * src/backend/utils/adt/rowtypes.c
 */
static VALUE
pg_text_dec_row(t_pg_coder *conv, char *input_line, int len, int _tuple, int _field, int enc_idx)
{
	t_pg_rowcoder *this = (t_pg_rowcoder *)conv;

	/* Return value: array */
	VALUE array;

	/* Current field */
	VALUE field_str;

	int fieldno;
	int expected_fields;
	char *output_ptr;
	char *cur_ptr;
	char *end_capa_ptr;
	t_typemap *p_typemap;

	p_typemap = DATA_PTR( this->typemap );
	expected_fields = p_typemap->funcs.fit_to_copy_get( this->typemap );

	/* The received input string will probably have this->nfields fields. */
	array = rb_ary_new2(expected_fields);

	/* Allocate a new string with embedded capacity and realloc later with
	 * exponential growing size when needed. */
	PG_RB_TAINTED_STR_NEW( field_str, output_ptr, end_capa_ptr );

	/* set pointer variables for loop */
	cur_ptr = input_line;

	/*
	 * Scan the string.  We use "buf" to accumulate the de-quoted data for
	 * each column, which is then fed to the appropriate input converter.
	 */
	/* Allow leading whitespace */
	while (*cur_ptr && row_isspace(*cur_ptr))
		cur_ptr++;
	if (*cur_ptr++ != '(')
		rb_raise( rb_eArgError, "malformed record literal: \"%s\" - Missing left parenthesis.", input_line );

	for (fieldno = 0; ; fieldno++)
	{
		/* Check for null: completely empty input means null */
		if (*cur_ptr == ',' || *cur_ptr == ')')
		{
			rb_ary_push(array, Qnil);
		}
		else
		{
			/* Extract string for this column */
			int inquote = 0;
			VALUE field_value;

			while (inquote || !(*cur_ptr == ',' || *cur_ptr == ')'))
			{
				char ch = *cur_ptr++;

				if (ch == '\0')
					rb_raise( rb_eArgError, "malformed record literal: \"%s\" - Unexpected end of input.", input_line );
				if (ch == '\\')
				{
					if (*cur_ptr == '\0')
						rb_raise( rb_eArgError, "malformed record literal: \"%s\" - Unexpected end of input.", input_line );
					PG_RB_STR_ENSURE_CAPA( field_str, 1, output_ptr, end_capa_ptr );
					*output_ptr++ = *cur_ptr++;
				}
				else if (ch == '"')
				{
					if (!inquote)
						inquote = 1;
					else if (*cur_ptr == '"')
					{
						/* doubled quote within quote sequence */
						PG_RB_STR_ENSURE_CAPA( field_str, 1, output_ptr, end_capa_ptr );
						*output_ptr++ = *cur_ptr++;
					}
					else
						inquote = 0;
				} else {
					PG_RB_STR_ENSURE_CAPA( field_str, 1, output_ptr, end_capa_ptr );
					/* Add ch to output string */
					*output_ptr++ = ch;
				}
			}

			/* Convert the column value */
			rb_str_set_len( field_str, output_ptr - RSTRING_PTR(field_str) );
			field_value = p_typemap->funcs.typecast_copy_get( p_typemap, field_str, fieldno, 0, enc_idx );

			rb_ary_push(array, field_value);

			if( field_value == field_str ){
				/* Our output string will be send to the user, so we can not reuse
				 * it for the next field. */
				PG_RB_TAINTED_STR_NEW( field_str, output_ptr, end_capa_ptr );
			}
			/* Reset the pointer to the start of the output/buffer string. */
			output_ptr = RSTRING_PTR(field_str);
		}

		/* Skip comma that separates prior field from this one */
		if (*cur_ptr == ',') {
			cur_ptr++;
		} else if (*cur_ptr == ')') {
			cur_ptr++;
			/* Done if we hit closing parenthesis */
			break;
		} else {
			rb_raise( rb_eArgError, "malformed record literal: \"%s\" - Too few columns.", input_line );
		}
	}

	/* Allow trailing whitespace */
	while (*cur_ptr && row_isspace(*cur_ptr))
		cur_ptr++;
	if (*cur_ptr)
		rb_raise( rb_eArgError, "malformed record literal: \"%s\" - Junk after right parenthesis.", input_line );

	return array;
}


void
init_pg_rowcoder()
{
	/* Document-class: PG::RowCoder < PG::Coder
	 *
	 * This is the base class for all type cast classes for COPY data,
	 */
	rb_cPG_RowCoder = rb_define_class_under( rb_mPG, "RowCoder", rb_cPG_Coder );
	rb_define_method( rb_cPG_RowCoder, "type_map=", pg_rowcoder_type_map_set, 1 );
	rb_define_method( rb_cPG_RowCoder, "type_map", pg_rowcoder_type_map_get, 0 );

	/* Document-class: PG::RowEncoder < PG::RowCoder */
	rb_cPG_RowEncoder = rb_define_class_under( rb_mPG, "RowEncoder", rb_cPG_RowCoder );
	rb_define_alloc_func( rb_cPG_RowEncoder, pg_rowcoder_encoder_allocate );
	/* Document-class: PG::RowDecoder < PG::RowCoder */
	rb_cPG_RowDecoder = rb_define_class_under( rb_mPG, "RowDecoder", rb_cPG_RowCoder );
	rb_define_alloc_func( rb_cPG_RowDecoder, pg_rowcoder_decoder_allocate );

	/* Make RDoc aware of the encoder classes... */
	/* rb_mPG_TextEncoder = rb_define_module_under( rb_mPG, "TextEncoder" ); */
	/* dummy = rb_define_class_under( rb_mPG_TextEncoder, "RowRow", rb_cPG_RowEncoder ); */
	pg_define_coder( "Row", pg_text_enc_row, rb_cPG_RowEncoder, rb_mPG_TextEncoder );
	/* rb_mPG_TextDecoder = rb_define_module_under( rb_mPG, "TextDecoder" ); */
	/* dummy = rb_define_class_under( rb_mPG_TextDecoder, "RowRow", rb_cPG_RowDecoder ); */
	pg_define_coder( "Row", pg_text_dec_row, rb_cPG_RowDecoder, rb_mPG_TextDecoder );
}
