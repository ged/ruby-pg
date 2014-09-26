/*
 * pg_copycoder.c - PG::Coder class extension
 *
 */

#include "pg.h"

#define ISOCTAL(c) (((c) >= '0') && ((c) <= '7'))
#define OCTVALUE(c) ((c) - '0')

VALUE rb_cPG_CopyCoder;
VALUE rb_cPG_CopyEncoder;
VALUE rb_cPG_CopyDecoder;

typedef struct {
	t_pg_coder comp;
	VALUE typemap;
	VALUE null_string;
	char delimiter;
} t_pg_copycoder;


/*
 * Document-class: PG::CopyCoder
 *
 * This is the base class for all type cast classes for COPY data,
 *
 */

static void
pg_copycoder_mark( t_pg_copycoder *this )
{
	rb_gc_mark(this->typemap);
}

static VALUE
pg_copycoder_encoder_allocate( VALUE klass )
{
	t_pg_copycoder *this;
	VALUE self = Data_Make_Struct( klass, t_pg_copycoder, pg_copycoder_mark, -1, this );
	pg_coder_init_encoder( self );
	this->typemap = Qnil;
	this->delimiter = '\t';
	this->null_string = rb_str_new_cstr("\\N");
	return self;
}

static VALUE
pg_copycoder_decoder_allocate( VALUE klass )
{
	t_pg_copycoder *this;
	VALUE self = Data_Make_Struct( klass, t_pg_copycoder, pg_copycoder_mark, -1, this );
	pg_coder_init_decoder( self );
	this->typemap = Qnil;
	this->delimiter = '\t';
	this->null_string = rb_str_new_cstr("\\N");
	return self;
}

static VALUE
pg_copycoder_delimiter_set(VALUE self, VALUE delimiter)
{
	t_pg_copycoder *this = DATA_PTR(self);
	StringValue(delimiter);
	if(RSTRING_LEN(delimiter) != 1)
		rb_raise( rb_eArgError, "delimiter size must be one byte");
	this->delimiter = *RSTRING_PTR(delimiter);
	return delimiter;
}

static VALUE
pg_copycoder_delimiter_get(VALUE self)
{
	t_pg_copycoder *this = DATA_PTR(self);
	return rb_str_new(&this->delimiter, 1);
}

static VALUE
pg_copycoder_null_string_set(VALUE self, VALUE null_string)
{
	t_pg_copycoder *this = DATA_PTR(self);
	StringValue(null_string);
	this->null_string = null_string;
	return null_string;
}

static VALUE
pg_copycoder_null_string_get(VALUE self)
{
	t_pg_copycoder *this = DATA_PTR(self);
	return this->null_string;
}

/*
 *
 */
static VALUE
pg_copycoder_type_map_set(VALUE self, VALUE type_map)
{
	t_pg_copycoder *this = DATA_PTR( self );

	if ( !NIL_P(type_map) && !rb_obj_is_kind_of(type_map, rb_cTypeMap) ){
		rb_raise( rb_eTypeError, "wrong elements type %s (expected some kind of PG::TypeMap)",
				rb_obj_classname( type_map ) );
	}
	this->typemap = type_map;

	return type_map;
}

/*
 *
 */
static VALUE
pg_copycoder_type_map_get(VALUE self)
{
	t_pg_copycoder *this = DATA_PTR( self );

	return this->typemap;
}


static int
pg_text_enc_copy_row(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	t_pg_copycoder *this = (t_pg_copycoder *)conv;
	t_pg_coder_enc_func enc_func;
	VALUE typemap;
	static t_pg_coder *p_elem_coder;
	int i;
	t_typemap *p_typemap;
	char *current_out;

	if( NIL_P(this->typemap) ){
		rb_raise( rb_eTypeError, "no type_map defined" );
	} else {
		p_typemap = DATA_PTR( this->typemap );
		typemap = p_typemap->fit_to_query( this->typemap, value );
		p_typemap = DATA_PTR( typemap );
	}

	*intermediate = rb_str_new(NULL, 0);
	current_out = RSTRING_PTR(*intermediate);

	for( i=0; i<RARRAY_LEN(value); i++){
		char *ptr1;
		char *ptr2;
		int strlen;
		int backslashs;
		VALUE subint;
		VALUE entry;

		entry = rb_ary_entry(value, i);

		if( i > 0 ){
			current_out = pg_ensure_str_capa( *intermediate, 1, current_out );
			*current_out++ = this->delimiter;
		}

		switch(TYPE(entry)){
			case T_NIL:
				current_out = pg_ensure_str_capa( *intermediate, RSTRING_LEN(this->null_string), current_out );
				memcpy( current_out, RSTRING_PTR(this->null_string), RSTRING_LEN(this->null_string) );
				current_out += RSTRING_LEN(this->null_string);
				break;
			default:
				p_elem_coder = p_typemap->typecast_query_param(typemap, entry, i);
				enc_func = pg_coder_enc_func(p_elem_coder);

				/* 1st pass for retiving the required memory space */
				strlen = enc_func(p_elem_coder, entry, NULL, &subint);

				if( strlen == -1 ){
					/* we can directly use String value in subint */
					strlen = RSTRING_LEN(subint);

					/* size of string assuming the worst case, that every character must be escaped. */
					current_out = pg_ensure_str_capa( *intermediate, strlen * 2, current_out );

					/* Copy string from subint with backslash escaping */
					for(ptr1 = RSTRING_PTR(subint); ptr1 < RSTRING_PTR(subint) + strlen; ptr1++) {
						/* Escape backslash itself, newline, carriage return, and the current delimiter character. */
						if(*ptr1 == '\\' || *ptr1 == '\n' || *ptr1 == '\r' || *ptr1 == this->delimiter){
							*current_out++ = '\\';
						}
						*current_out++ = *ptr1;
					}
				} else {
					/* 2nd pass for writing the data to prepared buffer */
					/* size of string assuming the worst case, that every character must be escaped. */
					current_out = pg_ensure_str_capa( *intermediate, strlen * 2, current_out );

					/* Place the unescaped string at current output position. */
					strlen = enc_func(p_elem_coder, entry, current_out, &subint);

					ptr1 = current_out;
					ptr2 = current_out + strlen;

					/* count required backlashs */
					for(backslashs = 0; ptr1 != ptr2; ptr1++) {
						/* Escape backslash itself, newline, carriage return, and the current delimiter character. */
						if(*ptr1 == '\\' || *ptr1 == '\n' || *ptr1 == '\r' || *ptr1 == this->delimiter){
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
						if(*ptr1 == '\\' || *ptr1 == '\n' || *ptr1 == '\r' || *ptr1 == this->delimiter){
							*--ptr2 = '\\';
						}
					}
				}
		}
	}
	current_out = pg_ensure_str_capa( *intermediate, 1, current_out );
	*current_out++ = '\n';

	rb_str_set_len( *intermediate, current_out - RSTRING_PTR(*intermediate) );

	return -1;
}


/*
 *	Return decimal value for a hexadecimal digit
 */
static int
GetDecimalFromHex(char hex)
{
	if (hex >= '0' && hex <= '9')
		return hex - '0';
	else if (hex >= 'a' && hex <= 'f')
		return hex - 'a' + 10;
	else if (hex >= 'A' && hex <= 'F')
		return hex - 'A' + 10;
	else
		return -1;
}

/*
 * Parse the current line into separate attributes (fields),
 * performing de-escaping as needed.
 *
 * All fields are gathered into a ruby Array. The de-escaped field data is written
 * into to a ruby String. This object is reused for non string columns.
 * For String columns the field value is directly used as return value and no
 * reuse of the memory is done.
 */
static VALUE
pg_text_dec_copy_row(t_pg_coder *conv, char *input_line, int len, int _tuple, int _field, int enc_idx)
{
	t_pg_copycoder *this = (t_pg_copycoder *)conv;

	/* Return value: array */
	VALUE array;

	/* Current field */
	VALUE field_str;

	char delimc = this->delimiter;
	int fieldno;
	int expected_fields;
	char *output_ptr;
	char *cur_ptr;
	char *line_end_ptr;
	t_typemap *p_typemap;

	if( NIL_P(this->typemap) ){
		rb_raise( rb_eTypeError, "no type_map defined" );
	} else {
		p_typemap = DATA_PTR( this->typemap );
		expected_fields = p_typemap->fit_to_copy_get( this->typemap );
	}

	/* The received input string will probably have this->nfields fields. */
	array = rb_ary_new2(expected_fields);

	field_str = rb_tainted_str_new(NULL, 0);
	output_ptr = RSTRING_PTR(field_str);

	/* set pointer variables for loop */
	cur_ptr = input_line;
	line_end_ptr = input_line + len;

	/* Outer loop iterates over fields */
	fieldno = 0;
	for (;;)
	{
		int found_delim = 0;
		char *start_ptr;
		char *end_ptr;
		int input_len;

		/* Remember start of field on input side */
		start_ptr = cur_ptr;

		/*
		 * Scan data for field.
		 *
		 * Note that in this loop, we are scanning to locate the end of field
		 * and also speculatively performing de-escaping.  Once we find the
		 * end-of-field, we can match the raw field contents against the null
		 * marker string.  Only after that comparison fails do we know that
		 * de-escaping is actually the right thing to do; therefore we *must
		 * not* throw any syntax errors before we've done the null-marker
		 * check.
		 */
		for (;;)
		{
			/* The current character in the input string. */
			char c;

			end_ptr = cur_ptr;
			if (cur_ptr >= line_end_ptr)
				break;
			c = *cur_ptr++;
			if (c == delimc){
				found_delim = 1;
				break;
			}
			if (c == '\n'){
				break;
			}
			if (c == '\\'){
				if (cur_ptr >= line_end_ptr)
					break;

				c = *cur_ptr++;
				switch (c){
					case '0':
					case '1':
					case '2':
					case '3':
					case '4':
					case '5':
					case '6':
					case '7':
						{
							/* handle \013 */
							int val;

							val = OCTVALUE(c);
							if (cur_ptr < line_end_ptr)
							{
								c = *cur_ptr;
								if (ISOCTAL(c))
								{
									cur_ptr++;
									val = (val << 3) + OCTVALUE(c);
									if (cur_ptr < line_end_ptr)
									{
										c = *cur_ptr;
										if (ISOCTAL(c))
										{
											cur_ptr++;
											val = (val << 3) + OCTVALUE(c);
										}
									}
								}
							}
							c = val & 0377;
						}
						break;
					case 'x':
						/* Handle \x3F */
						if (cur_ptr < line_end_ptr)
						{
							char hexchar = *cur_ptr;
							int val = GetDecimalFromHex(hexchar);;

							if (val >= 0)
							{
								cur_ptr++;
								if (cur_ptr < line_end_ptr)
								{
									int val2;
									hexchar = *cur_ptr;
									val2 = GetDecimalFromHex(hexchar);

									if (val2 >= 0)
									{
										cur_ptr++;
										val = (val << 4) + val2;
									}
								}
								c = val & 0xff;
							}
						}
						break;
					case 'b':
						c = '\b';
						break;
					case 'f':
						c = '\f';
						break;
					case 'n':
						c = '\n';
						break;
					case 'r':
						c = '\r';
						break;
					case 't':
						c = '\t';
						break;
					case 'v':
						c = '\v';
						break;

						/*
						 * in all other cases, take the char after '\'
						 * literally
						 */
				}
			}

			output_ptr = pg_ensure_str_capa( field_str, 1, output_ptr );
			/* Add c to output string */
			*output_ptr++ = c;
		}

		if (!found_delim && cur_ptr < line_end_ptr)
			rb_raise( rb_eArgError, "trailing data after linefeed at position: %ld", cur_ptr - input_line + 1 );


		/* Check whether raw input matched null marker */
		input_len = end_ptr - start_ptr;
		if (input_len == RSTRING_LEN(this->null_string) &&
					strncmp(start_ptr, RSTRING_PTR(this->null_string), input_len) == 0) {
			rb_ary_push(array, Qnil);
		} else {
			VALUE field_value;

			rb_str_set_len( field_str, output_ptr - RSTRING_PTR(field_str) );
			field_value = p_typemap->typecast_copy_get( p_typemap, field_str, fieldno, 0, enc_idx );

			rb_ary_push(array, field_value);

			if( field_value == field_str ){
				/* Our output string will be send to the user, so we can not reuse
				 * it for the next field. */
				field_str = rb_str_new(NULL, 0);
			}
		}
		output_ptr = RSTRING_PTR(field_str);

		fieldno++;
		/* Done if we hit EOL instead of a delim */
		if (!found_delim)
			break;
	}

	return array;
}


void
init_pg_copycoder()
{
	rb_cPG_CopyCoder = rb_define_class_under( rb_mPG, "CopyCoder", rb_cPG_Coder );
	rb_define_method( rb_cPG_CopyCoder, "type_map=", pg_copycoder_type_map_set, 1 );
	rb_define_method( rb_cPG_CopyCoder, "type_map", pg_copycoder_type_map_get, 0 );
	rb_define_method( rb_cPG_CopyCoder, "delimiter=", pg_copycoder_delimiter_set, 1 );
	rb_define_method( rb_cPG_CopyCoder, "delimiter", pg_copycoder_delimiter_get, 0 );
	rb_define_method( rb_cPG_CopyCoder, "null_string=", pg_copycoder_null_string_set, 1 );
	rb_define_method( rb_cPG_CopyCoder, "null_string", pg_copycoder_null_string_get, 0 );

	rb_cPG_CopyEncoder = rb_define_class_under( rb_mPG, "CopyEncoder", rb_cPG_CopyCoder );
	rb_define_alloc_func( rb_cPG_CopyEncoder, pg_copycoder_encoder_allocate );
	rb_cPG_CopyDecoder = rb_define_class_under( rb_mPG, "CopyDecoder", rb_cPG_CopyCoder );
	rb_define_alloc_func( rb_cPG_CopyDecoder, pg_copycoder_decoder_allocate );

	pg_define_coder( "CopyRow", pg_text_enc_copy_row, rb_cPG_CopyEncoder, rb_mPG_TextEncoder );
	pg_define_coder( "CopyRow", pg_text_dec_copy_row, rb_cPG_CopyDecoder, rb_mPG_TextDecoder );
}
