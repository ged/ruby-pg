/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_Type;
VALUE rb_cPG_Type_CConverter;
VALUE rb_mPG_Type_Text;
VALUE rb_mPG_Type_Binary;


static VALUE
pg_type_dec_text_boolean(char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for text boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 't' ? Qtrue : Qfalse;
}

static VALUE
pg_type_dec_binary_boolean(char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for binary boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 0 ? Qfalse : Qtrue;
}

VALUE
pg_type_dec_text_string(char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE ret = rb_tainted_str_new( val, len );
#ifdef M17N_SUPPORTED
	ENCODING_SET_INLINED( ret, enc_idx );
#endif
	return ret;
}

static VALUE
pg_type_dec_text_integer(char *val, int len, int tuple, int field, int enc_idx)
{
	return rb_cstr2inum(val, 10);
}

static VALUE
pg_type_dec_binary_integer(char *val, int len, int tuple, int field, int enc_idx)
{
	switch( len ){
		case 2:
			return INT2NUM((int16_t)be16toh(*(int16_t*)val));
		case 4:
			return LONG2NUM((int32_t)be32toh(*(int32_t*)val));
		case 8:
			return LL2NUM((int64_t)be64toh(*(int64_t*)val));
		default:
			rb_raise( rb_eTypeError, "wrong data for binary integer converter in tuple %d field %d length %d", tuple, field, len);
	}
}

static VALUE
pg_type_dec_text_float(char *val, int len, int tuple, int field, int enc_idx)
{
	return rb_float_new(strtod(val, NULL));
}

static VALUE
pg_type_dec_binary_float(char *val, int len, int tuple, int field, int enc_idx)
{
	union {
		float f;
		int32_t i;
	} swap4;
	union {
		double f;
		int64_t i;
	} swap8;

	switch( len ){
		case 4:
			swap4.f = *(float *)val;
			swap4.i = be32toh(swap4.i);
			return rb_float_new(swap4.f);
		case 8:
			swap8.f = *(double *)val;
			swap8.i = be64toh(swap8.i);
			return rb_float_new(swap8.f);
		default:
			rb_raise( rb_eTypeError, "wrong data for BinaryFloat converter in tuple %d field %d length %d", tuple, field, len);
	}
}

static VALUE
pg_type_dec_text_bytea(char *val, int len, int tuple, int field, int enc_idx)
{
	unsigned char *to;
	size_t to_len;
	VALUE ret;

	to = PQunescapeBytea( (unsigned char *)val, &to_len);

	ret = rb_tainted_str_new((char*)to, to_len);
	PQfreemem(to);

	return ret;
}

VALUE
pg_type_dec_binary_bytea(char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE ret;
	ret = rb_tainted_str_new( val, len );
#ifdef M17N_SUPPORTED
	rb_enc_associate( ret, rb_ascii8bit_encoding() );
#endif
	return ret;
}

/*
 * Array parser functions are thankfully borrowed from here:
 * https://github.com/dockyard/pg_array_parser
 */
VALUE read_array(int *index, char *c_pg_array_string, int array_string_length, char *word, int enc_idx, int tuple, int field, t_type_converter_dec_func dec_func)
{
	/* Return value: array */
	VALUE array;
	int word_index = 0;

	/* The current character in the input string. */
	char c;

	/*  0: Currently outside a quoted string, current word never quoted
	*  1: Currently inside a quoted string
	* -1: Currently outside a quoted string, current word previously quoted */
	int openQuote = 0;

	/* Inside quoted input means the next character should be treated literally,
	* instead of being treated as a metacharacter.
	* Outside of quoted input, means that the word shouldn't be pushed to the array,
	* used when the last entry was a subarray (which adds to the array itself). */
	int escapeNext = 0;

	array = rb_ary_new();

	/* Special case the empty array, so it doesn't need to be handled manually inside
	* the loop. */
	if(((*index) < array_string_length) && c_pg_array_string[(*index)] == '}')
	{
		return array;
	}

	for(;(*index) < array_string_length; ++(*index))
	{
		c = c_pg_array_string[*index];
		if(openQuote < 1)
		{
			if(c == ',' || c == '}')
			{
				if(!escapeNext)
				{
					if(openQuote == 0 && word_index == 4 && !strncmp(word, "NULL", word_index))
					{
						rb_ary_push(array, Qnil);
					}
					else
					{
						VALUE val;
						word[word_index] = 0;
						val = dec_func(word, word_index, tuple, field, enc_idx);
						rb_ary_push(array, val);
					}
				}
				if(c == '}')
				{
					return array;
				}
				escapeNext = 0;
				openQuote = 0;
				word_index = 0;
			}
			else if(c == '"')
			{
				openQuote = 1;
			}
			else if(c == '{')
			{
				(*index)++;
				rb_ary_push(array, read_array(index, c_pg_array_string, array_string_length, word, enc_idx, tuple, field, dec_func));
				escapeNext = 1;
			}
			else
			{
				word[word_index] = c;
				word_index++;
			}
		}
		else if (escapeNext) {
			word[word_index] = c;
			word_index++;
			escapeNext = 0;
		}
		else if (c == '\\')
		{
			escapeNext = 1;
		}
		else if (c == '"')
		{
			openQuote = -1;
		}
		else
		{
			word[word_index] = c;
			word_index++;
		}
	}

	return array;
}

static VALUE
pg_type_dec_text_array_helper(char *val, int len, int tuple, int field, int enc_idx, t_type_converter_dec_func dec_func)
{
	/* create a buffer of the same length, as that will be the worst case */
	char *word = xmalloc(len + 1);
	int index = 1;

	VALUE return_value = read_array(&index, val, len, word, enc_idx, tuple, field, dec_func);
	free(word);
	return return_value;
}

static VALUE
pg_type_dec_text_int_array(char *val, int len, int tuple, int field, int enc_idx)
{
	return pg_type_dec_text_array_helper(val, len, tuple, field, enc_idx, pg_type_dec_text_integer);
}

static VALUE
pg_type_dec_text_text_array(char *val, int len, int tuple, int field, int enc_idx)
{
	return pg_type_dec_text_array_helper(val, len, tuple, field, enc_idx, pg_type_dec_text_string);
}

static VALUE
pg_type_dec_text_float_array(char *val, int len, int tuple, int field, int enc_idx)
{
	return pg_type_dec_text_array_helper(val, len, tuple, field, enc_idx, pg_type_dec_text_float);
}


static int
pg_type_enc_binary_boolean(VALUE value, char *out, VALUE *intermediate)
{
	char bool;
	switch(value){
		case Qtrue : bool = 1; break;
		case Qfalse : bool = 0; break;
		default :
			rb_raise( rb_eTypeError, "wrong data for binary boolean converter" );
	}
	if(out) *out = bool;
	return 1;
}

static int
pg_type_enc_to_str(VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		memcpy( out, RSTRING_PTR(*intermediate), RSTRING_LEN(*intermediate));
	} else {
		*intermediate = rb_obj_as_string(value);
	}

	return RSTRING_LEN(*intermediate);
}


static int
pg_type_enc_binary_int2(VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int16_t*)out = htobe16(NUM2INT(value));
	return 2;
}

static int
pg_type_enc_binary_int4(VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int32_t*)out = htobe32(NUM2LONG(value));
	return 4;
}

static int
pg_type_enc_binary_int8(VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int64_t*)out = htobe64(NUM2LL(value));
	return 8;
}

static int
pg_type_enc_text_integer(VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		long long ll = NUM2LL(*intermediate);
		if( ll < 100000000000000 ){
			return sprintf(out, "%lld", NUM2LL(*intermediate));
		}else{
			return pg_type_enc_to_str(value, out, intermediate);
		}
	}else{
		long long ll;
		*intermediate = rb_to_int(value);
		ll = NUM2LL(*intermediate);
		if( ll < 100000000 ){
			if( ll < 10000 ){
				if( ll < 100 ){
					return ll < 10 ? 1 : 2;
				}else{
					return ll < 1000 ? 3 : 4;
				}
			}else{
				if( ll < 1000000 ){
					return ll < 100000 ? 5 : 6;
				}else{
					return ll < 10000000 ? 7 : 8;
				}
			}
		}else{
			if( ll < 1000000000000 ){
				if( ll < 10000000000 ){
					return ll < 1000000000 ? 9 : 10;
				}else{
					return ll < 100000000000 ? 11 : 12;
				}
			}else{
				if( ll < 100000000000000 ){
					return ll < 10000000000000 ? 13 : 14;
				}else{
					return pg_type_enc_to_str(*intermediate, NULL, intermediate);
				}
			}
		}
	}
}

static int
write_array(VALUE value, char *out, VALUE *intermediate, t_type_converter_enc_func enc_func, int quote, int *interm_pos)
{
	int i;
	if(out){
		char *current_out = out;

		if( *interm_pos < 0 ) *interm_pos = 0;

		*current_out++ = '{';
		for( i=0; i<RARRAY_LEN(value); i++){
			char *buffer;
			int j;
			int strlen;
			VALUE subint;
			VALUE entry = rb_ary_entry(value, i);
			if( i > 0 ) *current_out++ = ',';
			switch(TYPE(entry)){
				case T_ARRAY:
					current_out += write_array(entry, current_out, intermediate, enc_func, quote, interm_pos);
				break;
				case T_NIL:
					*current_out++ = 'N';
					*current_out++ = 'U';
					*current_out++ = 'L';
					*current_out++ = 'L';
					break;
				default:
					subint = rb_ary_entry(*intermediate, *interm_pos);
					*interm_pos = *interm_pos + 1;
					if(quote){
						/* place the unquoted string at the most right side of the precalculated
						* worst case size. Then store the quoted string on the desired position.
						*/
						buffer = current_out + enc_func(subint, NULL, &subint) + 2;
						strlen = enc_func(entry, buffer, &subint);

						*current_out++ = '"';
						for(j = 0; j < strlen; j++) {
							if(buffer[j] == '"' || buffer[j] == '\\'){
								*current_out++ = '\\';
							}
							*current_out++ = buffer[j];
						}
						*current_out++ = '"';
					}else{
						current_out += enc_func(entry, current_out, &subint);
					}
			}
		}
		*current_out++ = '}';
		return current_out - out;

	} else {
		int sumlen = 0;
		Check_Type(value, T_ARRAY);

		if( *interm_pos < 0 ){
			*intermediate = rb_ary_new();
			*interm_pos = 0;
		}

		for( i=0; i<RARRAY_LEN(value); i++){
			VALUE subint;
			VALUE entry = rb_ary_entry(value, i);
			switch(TYPE(entry)){
				case T_ARRAY:
					/* size of array content */
					sumlen += write_array(entry, NULL, intermediate, enc_func, quote, interm_pos);
				break;
				case T_NIL:
					/* size of "NULL" */
					sumlen += 4;
					break;
				default:
					if(quote){
						/* size of string assuming the worst case, that every character must be escaped
						* plus two bytes for quotation.
						*/
						sumlen += 2 * enc_func(entry, NULL, &subint) + 2;
					}else{
						/* size of the unquoted string */
						sumlen += enc_func(entry, NULL, &subint);
					}
					rb_ary_push(*intermediate, subint);
			}
		}

		/* size of "{" plus content plus n-1 times "," plus "}" */
		return 1 + sumlen + RARRAY_LEN(value) - 1 + 1;
	}
}

static int
pg_type_enc_text_array_to_str(VALUE value, char *out, VALUE *intermediate)
{
	int pos = -1;
	return write_array(value, out, intermediate, pg_type_enc_to_str, 1, &pos);
}

static int
pg_type_enc_text_integer_array(VALUE value, char *out, VALUE *intermediate)
{
	int pos = -1;
	return write_array(value, out, intermediate, pg_type_enc_text_integer, 0, &pos);
}

static int
pg_type_enc_text_number_array(VALUE value, char *out, VALUE *intermediate)
{
	int pos = -1;
	return write_array(value, out, intermediate, pg_type_enc_to_str, 0, &pos);
}

static VALUE
pg_type_encode(VALUE self, VALUE value)
{
	VALUE res = rb_str_new_cstr("");
	VALUE intermediate;
	int len;
	struct pg_type_cconverter *type_data = DATA_PTR(self);

	if( !type_data->enc_func ){
		rb_raise( rb_eArgError, "no encoder defined for type %s",
				rb_obj_classname( self ) );
	}

	len = type_data->enc_func( value, NULL, &intermediate );
	res = rb_str_resize( res, len );
	len = type_data->enc_func( value, RSTRING_PTR(res), &intermediate);
	rb_str_set_len( res, len );
	return res;
}

static VALUE
pg_type_decode(int argc, VALUE *argv, VALUE self)
{
	char *val;
	VALUE tuple = -1;
	VALUE field = -1;
	struct pg_type_cconverter *type_data = DATA_PTR(self);

	if(argc < 1 || argc > 3){
		rb_raise(rb_eArgError, "wrong number of arguments (%i for 1..3)", argc);
	}else if(argc >= 3){
		tuple = NUM2INT(argv[1]);
		field = NUM2INT(argv[2]);
	}

	if( !type_data->dec_func ){
		rb_raise( rb_eArgError, "no decoder defined for type %s",
				rb_obj_classname( self ) );
	}
	val = StringValuePtr(argv[0]);
	return type_data->dec_func(val, RSTRING_LEN(argv[0]), tuple, field, ENCODING_GET(argv[0]));
}

static VALUE
pg_type_oid(VALUE self)
{
	struct pg_type_cconverter *type_data = DATA_PTR(self);
	return INT2NUM(type_data->oid);
}

static VALUE
pg_type_format(VALUE self)
{
	struct pg_type_cconverter *type_data = DATA_PTR(self);
	return INT2NUM(type_data->format);
}


static void
pg_type_define_type(int format, const char *name, t_type_converter_enc_func enc_func, t_type_converter_dec_func dec_func, Oid oid)
{
	struct pg_type_cconverter *sval;
	VALUE type_obj;
	VALUE cFormatModule;
	VALUE klass;

	switch( format ){
		case 0:
			cFormatModule = rb_mPG_Type_Text;
			break;
		case 1:
			cFormatModule = rb_mPG_Type_Binary;
			break;
		default:
			rb_bug( "invalid format %i", format );
	}

	klass = rb_class_new(rb_cPG_Type_CConverter);
	rb_name_class(klass, rb_intern(name));
	type_obj = Data_Make_Struct( klass, struct pg_type_cconverter, NULL, -1, sval );
	sval->enc_func = enc_func;
	sval->dec_func = dec_func;
	sval->oid = oid;
	sval->format = format;
	rb_iv_set( type_obj, "@name", rb_obj_freeze(rb_str_new_cstr(name)) );
	if( enc_func ) rb_define_method( klass, "encode", pg_type_encode, 1 );
	if( dec_func ) rb_define_method( klass, "decode", pg_type_decode, -1 );

	rb_define_const( cFormatModule, name, type_obj );

	RB_GC_GUARD(klass);
	RB_GC_GUARD(type_obj);
}


void
init_pg_type()
{
	rb_mPG_Type = rb_define_module_under( rb_mPG, "Type" );
	rb_cPG_Type_CConverter = rb_define_class_under( rb_mPG_Type, "CConverter", rb_cObject );
	rb_define_method( rb_cPG_Type_CConverter, "oid", pg_type_oid, 0 );
	rb_define_method( rb_cPG_Type_CConverter, "format", pg_type_format, 0 );
	rb_define_attr( rb_cPG_Type_CConverter, "name", 1, 0 );
	rb_mPG_Type_Text = rb_define_module_under( rb_mPG_Type, "Text" );
	rb_mPG_Type_Binary = rb_define_module_under( rb_mPG_Type, "Binary" );

	pg_type_define_type( 0, "BOOLEAN", pg_type_enc_to_str, pg_type_dec_text_boolean, 16 );
	pg_type_define_type( 0, "BYTEA", pg_type_enc_to_str, pg_type_dec_text_bytea, 17 );
	pg_type_define_type( 0, "INT8", pg_type_enc_text_integer, pg_type_dec_text_integer, 20 );
	pg_type_define_type( 0, "INT2", pg_type_enc_text_integer, pg_type_dec_text_integer, 21 );
	pg_type_define_type( 0, "INT4", pg_type_enc_text_integer, pg_type_dec_text_integer, 23 );
	pg_type_define_type( 0, "INT2ARRAY", pg_type_enc_text_integer_array, pg_type_dec_text_int_array, 1005 );
	pg_type_define_type( 0, "INT4ARRAY", pg_type_enc_text_integer_array, pg_type_dec_text_int_array, 1007 );
	pg_type_define_type( 0, "TEXTARRAY", pg_type_enc_text_array_to_str, pg_type_dec_text_text_array, 1009 );
	pg_type_define_type( 0, "VARCHARARRAY", pg_type_enc_text_array_to_str, pg_type_dec_text_text_array, 1015 );
	pg_type_define_type( 0, "INT8ARRAY", pg_type_enc_text_integer_array, pg_type_dec_text_int_array, 1016 );
	pg_type_define_type( 0, "FLOAT4ARRAY", pg_type_enc_text_number_array, pg_type_dec_text_float_array, 1021 );
	pg_type_define_type( 0, "FLOAT8ARRAY", pg_type_enc_text_number_array, pg_type_dec_text_float_array, 1022 );
	pg_type_define_type( 0, "FLOAT4", pg_type_enc_to_str, pg_type_dec_text_float, 700 );
	pg_type_define_type( 0, "FLOAT8", pg_type_enc_to_str, pg_type_dec_text_float, 701 );
	pg_type_define_type( 0, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 25 );

	pg_type_define_type( 1, "BOOLEAN", pg_type_enc_binary_boolean, pg_type_dec_binary_boolean, 16 );
	pg_type_define_type( 1, "BYTEA", pg_type_enc_to_str, pg_type_dec_binary_bytea, 17 );
	pg_type_define_type( 1, "INT8", pg_type_enc_binary_int8, pg_type_dec_binary_integer, 20 );
	pg_type_define_type( 1, "INT2", pg_type_enc_binary_int2, pg_type_dec_binary_integer, 21 );
	pg_type_define_type( 1, "INT4", pg_type_enc_binary_int4, pg_type_dec_binary_integer, 23 );
	pg_type_define_type( 1, "FLOAT4", NULL, pg_type_dec_binary_float, 700 );
	pg_type_define_type( 1, "FLOAT8", NULL, pg_type_dec_binary_float, 701 );
	pg_type_define_type( 1, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 25 );
}
