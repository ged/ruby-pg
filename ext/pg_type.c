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
VALUE rb_cPG_Type_CompositeCConverter;
VALUE rb_mPG_Type_Text;
VALUE rb_mPG_Type_Binary;
static ID s_id_encode;
static ID s_id_decode;
static ID s_id_oid;
static ID s_id_format;


static VALUE
pg_type_dec_text_boolean(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for text boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 't' ? Qtrue : Qfalse;
}

static VALUE
pg_type_dec_binary_boolean(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for binary boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 0 ? Qfalse : Qtrue;
}

VALUE
pg_type_dec_text_string(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE ret = rb_tainted_str_new( val, len );
#ifdef M17N_SUPPORTED
	ENCODING_SET_INLINED( ret, enc_idx );
#endif
	return ret;
}

static VALUE
pg_type_dec_text_integer(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	return rb_cstr2inum(val, 10);
}

static VALUE
pg_type_dec_binary_integer(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
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
pg_type_dec_text_float(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	return rb_float_new(strtod(val, NULL));
}

static VALUE
pg_type_dec_binary_float(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
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
pg_type_dec_text_bytea(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
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
pg_type_dec_binary_bytea(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
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
VALUE read_array(t_type_converter *conv, int *index, char *c_pg_array_string, int array_string_length, char *word, int enc_idx, int tuple, int field, t_type_converter_dec_func dec_func)
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
						val = dec_func(conv, word, word_index, tuple, field, enc_idx);
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
				rb_ary_push(array, read_array(conv, index, c_pg_array_string, array_string_length, word, enc_idx, tuple, field, dec_func));
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
pg_type_dec_text_array_helper(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx, t_type_converter_dec_func dec_func)
{
	/* create a buffer of the same length, as that will be the worst case */
	char *word = xmalloc(len + 1);
	int index = 1;

	VALUE return_value = read_array(conv, &index, val, len, word, enc_idx, tuple, field, dec_func);
	free(word);
	return return_value;
}

static VALUE
pg_type_dec_text_in_ruby(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE string = pg_type_dec_text_string(conv, val, len, tuple, field, enc_idx);
	return rb_funcall( conv->type, s_id_decode, 3, string, INT2NUM(tuple), INT2NUM(field) );
}

static VALUE
pg_type_dec_text_array(t_type_converter *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	struct pg_type_composite_cconverter *comp_conv = (struct pg_type_composite_cconverter *)conv;
	if( comp_conv->elem.dec_func ){
		return pg_type_dec_text_array_helper(&comp_conv->elem, val, len, tuple, field, enc_idx, comp_conv->elem.dec_func);
	}else{
		return pg_type_dec_text_array_helper(&comp_conv->elem, val, len, tuple, field, enc_idx, pg_type_dec_text_in_ruby);
	}
}


static int
pg_type_enc_binary_boolean(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
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
pg_type_enc_to_str(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		memcpy( out, RSTRING_PTR(*intermediate), RSTRING_LEN(*intermediate));
	} else {
		*intermediate = rb_obj_as_string(value);
	}

	return RSTRING_LEN(*intermediate);
}


static int
pg_type_enc_binary_int2(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int16_t*)out = htobe16(NUM2INT(value));
	return 2;
}

static int
pg_type_enc_binary_int4(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int32_t*)out = htobe32(NUM2LONG(value));
	return 4;
}

static int
pg_type_enc_binary_int8(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int64_t*)out = htobe64(NUM2LL(value));
	return 8;
}

static int
pg_type_enc_text_integer(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		if(TYPE(*intermediate) == T_STRING){
			return pg_type_enc_to_str(conv, value, out, intermediate);
		}else{
			return sprintf(out, "%lld", NUM2LL(*intermediate));
		}
	}else{
		*intermediate = rb_to_int(value);
		if(TYPE(*intermediate) == T_FIXNUM){
			long long ll = NUM2LL(*intermediate);
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
						return pg_type_enc_to_str(conv, *intermediate, NULL, intermediate);
					}
				}
			}
		}else{
			return pg_type_enc_to_str(conv, *intermediate, NULL, intermediate);
		}
	}
}

static int
pg_type_enc_text_float(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		return sprintf( out, "%.16E", NUM2DBL(value));
	}else{
		*intermediate = value;
		return 23;
	}
}

static int
write_array(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate, t_type_converter_enc_func enc_func, int quote, int *interm_pos)
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
					current_out += write_array(conv, entry, current_out, intermediate, enc_func, quote, interm_pos);
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
						buffer = current_out + enc_func(conv, subint, NULL, &subint) + 2;
						strlen = enc_func(conv, entry, buffer, &subint);

						*current_out++ = '"';
						for(j = 0; j < strlen; j++) {
							if(buffer[j] == '"' || buffer[j] == '\\'){
								*current_out++ = '\\';
							}
							*current_out++ = buffer[j];
						}
						*current_out++ = '"';
					}else{
						current_out += enc_func(conv, entry, current_out, &subint);
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
					sumlen += write_array(conv, entry, NULL, intermediate, enc_func, quote, interm_pos);
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
						sumlen += 2 * enc_func(conv, entry, NULL, &subint) + 2;
					}else{
						/* size of the unquoted string */
						sumlen += enc_func(conv, entry, NULL, &subint);
					}
					rb_ary_push(*intermediate, subint);
			}
		}

		/* size of "{" plus content plus n-1 times "," plus "}" */
		return 1 + sumlen + RARRAY_LEN(value) - 1 + 1;
	}
}

static int
pg_type_enc_text_in_ruby(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	if( out ){
		memcpy(out, RSTRING_PTR(*intermediate), RSTRING_LEN(*intermediate));
		return RSTRING_LEN(*intermediate);
	}else{
		*intermediate = rb_funcall( conv->type, s_id_encode, 1, value );
		return RSTRING_LEN(*intermediate);
	}
}

static int
pg_type_enc_text_array(t_type_converter *conv, VALUE value, char *out, VALUE *intermediate)
{
	struct pg_type_composite_cconverter *comp_conv = (struct pg_type_composite_cconverter *)conv;
	int pos = -1;
	if( comp_conv->elem.enc_func ){
		return write_array(&comp_conv->elem, value, out, intermediate, comp_conv->elem.enc_func, comp_conv->needs_quotation, &pos);
	}else{
		return write_array(&comp_conv->elem, value, out, intermediate, pg_type_enc_text_in_ruby, comp_conv->needs_quotation, &pos);
	}
}

t_type_converter *
pg_type_get_and_check( VALUE self )
{
	Check_Type(self, T_DATA);

	if ( !rb_obj_is_kind_of(self, rb_cPG_Type_CConverter) ) {
		rb_raise( rb_eTypeError, "wrong argument type %s (expected PG::Type)",
				rb_obj_classname( self ) );
	}

	return DATA_PTR( self );
}

VALUE
pg_type_use_or_wrap( VALUE self, t_type_converter **cconv, int argument_nr )
{
	VALUE wrap_obj = Qnil;

	if( TYPE(self) == T_SYMBOL ){
		self = rb_const_get(rb_mPG_Type_Text, rb_to_id(self));
	}

	if( self == Qnil ){
		/* no type cast */
		*cconv = NULL;
	} else if( rb_obj_is_kind_of(self, rb_cPG_Type_CConverter) ){
		/* type cast with C implementation */
		Check_Type(self, T_DATA);
		*cconv = DATA_PTR(self);
	} else if( rb_respond_to(self, s_id_oid) && rb_respond_to(self, s_id_format)){
		/* type cast with Ruby implementation */
		VALUE oid = rb_funcall(self, s_id_oid, 0);
		VALUE format = rb_funcall(self, s_id_format, 0);
		wrap_obj = Data_Make_Struct( rb_cPG_Type_CConverter, struct pg_type_cconverter, NULL, -1, *cconv );
		(*cconv)->dec_func = NULL;
		(*cconv)->enc_func = NULL;
		(*cconv)->oid = NUM2INT(oid);
		(*cconv)->format = NUM2INT(format);
		(*cconv)->type = self;
	} else {
		rb_raise(rb_eArgError, "invalid type argument %d", argument_nr);
	}

	RB_GC_GUARD(wrap_obj);

	return wrap_obj;
}

static VALUE
pg_type_encode(VALUE self, VALUE value)
{
	VALUE res = rb_str_new_cstr("");
	VALUE intermediate;
	int len;
	t_type_converter *type_data = DATA_PTR(self);

	if( !type_data->enc_func ){
		rb_raise( rb_eArgError, "no encoder defined for type %s",
				rb_obj_classname( self ) );
	}

	len = type_data->enc_func( type_data, value, NULL, &intermediate );
	res = rb_str_resize( res, len );
	len = type_data->enc_func( type_data, value, RSTRING_PTR(res), &intermediate);
	rb_str_set_len( res, len );
	return res;
}

static VALUE
pg_type_decode(int argc, VALUE *argv, VALUE self)
{
	char *val;
	VALUE tuple = -1;
	VALUE field = -1;
	t_type_converter *type_data = DATA_PTR(self);

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
	return type_data->dec_func(type_data, val, RSTRING_LEN(argv[0]), tuple, field, ENCODING_GET(argv[0]));
}

static VALUE
pg_type_oid(VALUE self)
{
	t_type_converter *type_data = DATA_PTR(self);
	return INT2NUM(type_data->oid);
}

static VALUE
pg_type_format(VALUE self)
{
	t_type_converter *type_data = DATA_PTR(self);
	return INT2NUM(type_data->format);
}

static VALUE
pg_type_build_type(int format, const char *name, t_type_converter_enc_func enc_func, t_type_converter_dec_func dec_func, Oid oid)
{
	t_type_converter *sval;
	VALUE type_obj;
	VALUE klass;

	klass = rb_class_new(rb_cPG_Type_CConverter);
	rb_name_class(klass, rb_intern(name));
	type_obj = Data_Make_Struct( klass, t_type_converter, NULL, -1, sval );
	sval->enc_func = enc_func;
	sval->dec_func = dec_func;
	sval->oid = oid;
	sval->format = format;
	sval->type = type_obj;
	rb_iv_set( type_obj, "@name", rb_obj_freeze(rb_str_new_cstr(name)) );
	if( enc_func ) rb_define_method( klass, "encode", pg_type_encode, 1 );
	if( dec_func ) rb_define_method( klass, "decode", pg_type_decode, -1 );

	RB_GC_GUARD(klass);
	RB_GC_GUARD(type_obj);

	return type_obj;
}

static VALUE
pg_type_build(VALUE self, VALUE oid)
{
	t_type_converter *type_data = pg_type_get_and_check(self);
	char * name = RSTRING_PTR( rb_iv_get( self, "@name" ) );

	return pg_type_build_type( type_data->format, name, type_data->enc_func, type_data->dec_func, NUM2INT(oid));
}

static VALUE
pg_type_define_type(int format, const char *name, t_type_converter_enc_func enc_func, t_type_converter_dec_func dec_func, Oid oid)
{
	VALUE type_obj;
	VALUE cFormatModule;

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

	type_obj = pg_type_build_type( format, name, enc_func, dec_func, oid );
	rb_define_const( cFormatModule, name, type_obj );

	RB_GC_GUARD(type_obj);

	return type_obj;
}


static VALUE
pg_type_build_composite_type(int format, const char *name,
		t_type_converter_enc_func enc_func, t_type_converter_dec_func dec_func )
{
	struct pg_type_composite_cconverter *sval;
	VALUE type_obj;
	VALUE klass;

	klass = rb_class_new(rb_cPG_Type_CompositeCConverter);
	rb_name_class(klass, rb_intern(name));
	type_obj = Data_Make_Struct( klass, struct pg_type_composite_cconverter, NULL, -1, sval );
	sval->comp.enc_func = enc_func;
	sval->comp.dec_func = dec_func;
	sval->comp.format = format;
	sval->comp.type = type_obj;

	rb_iv_set( type_obj, "@name", rb_obj_freeze(rb_str_new_cstr(name)) );
	if( enc_func ) rb_define_method( klass, "encode", pg_type_encode, 1 );
	if( dec_func ) rb_define_method( klass, "decode", pg_type_decode, -1 );

	RB_GC_GUARD(klass);
	RB_GC_GUARD(type_obj);

	return type_obj;
}

static VALUE
pg_type_build_composite(VALUE self, VALUE name, VALUE elem_type, VALUE needs_quotation, VALUE oid)
{
	struct pg_type_composite_cconverter *sval;
	VALUE type_obj;
	t_type_converter *type_data = pg_type_get_and_check(self);
	t_type_converter *elem_conv;
	VALUE wrap_obj = pg_type_use_or_wrap( elem_type, &elem_conv, 2 );

	type_obj = pg_type_build_composite_type( type_data->format, StringValuePtr(name),
			type_data->enc_func, type_data->dec_func );

	sval = DATA_PTR(type_obj);
	sval->comp.oid = NUM2INT(oid);
	sval->needs_quotation = RTEST(needs_quotation);
	sval->elem = *elem_conv;

	RB_GC_GUARD(wrap_obj);
	RB_GC_GUARD(type_obj);

	return type_obj;
}

static VALUE
pg_type_define_composite_type(int format, const char *name,
		t_type_converter_enc_func enc_func, t_type_converter_dec_func dec_func)
{
	VALUE type_obj;
	VALUE cFormatModule;

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

	type_obj = pg_type_build_composite_type( format, name, enc_func, dec_func );
	rb_define_const( cFormatModule, name, type_obj );

	RB_GC_GUARD(type_obj);

	return type_obj;
}


void
init_pg_type()
{
	s_id_encode = rb_intern("encode");
	s_id_decode = rb_intern("decode");
	s_id_oid = rb_intern("oid");
	s_id_format = rb_intern("format");

	rb_mPG_Type = rb_define_module_under( rb_mPG, "Type" );

	rb_cPG_Type_CConverter = rb_define_class_under( rb_mPG_Type, "CConverter", rb_cObject );
	rb_define_method( rb_cPG_Type_CConverter, "oid", pg_type_oid, 0 );
	rb_define_method( rb_cPG_Type_CConverter, "format", pg_type_format, 0 );
	rb_define_method( rb_cPG_Type_CConverter, "build", pg_type_build, 1 );
	rb_define_attr( rb_cPG_Type_CConverter, "name", 1, 0 );

	rb_cPG_Type_CompositeCConverter = rb_define_class_under( rb_mPG_Type, "CompositeCConverter", rb_cPG_Type_CConverter );
	rb_define_method( rb_cPG_Type_CompositeCConverter, "build", pg_type_build_composite, 4 );

	rb_mPG_Type_Text = rb_define_module_under( rb_mPG_Type, "Text" );
	rb_mPG_Type_Binary = rb_define_module_under( rb_mPG_Type, "Binary" );

	pg_type_define_type( 0, "BOOLEAN", pg_type_enc_to_str, pg_type_dec_text_boolean, 16 );
	pg_type_define_type( 0, "BYTEA", pg_type_enc_to_str, pg_type_dec_text_bytea, 17 );
	pg_type_define_type( 0, "INT8", pg_type_enc_text_integer, pg_type_dec_text_integer, 20 );
	pg_type_define_type( 0, "INT2", pg_type_enc_text_integer, pg_type_dec_text_integer, 21 );
	pg_type_define_type( 0, "INT4", pg_type_enc_text_integer, pg_type_dec_text_integer, 23 );
	pg_type_define_type( 0, "FLOAT4", pg_type_enc_text_float, pg_type_dec_text_float, 700 );
	pg_type_define_type( 0, "FLOAT8", pg_type_enc_text_float, pg_type_dec_text_float, 701 );
	pg_type_define_type( 0, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 25 );
	pg_type_define_type( 0, "VARCHAR", pg_type_enc_to_str, pg_type_dec_text_string, 1043 );

	pg_type_define_composite_type( 0, "ARRAY", pg_type_enc_text_array, pg_type_dec_text_array );

	pg_type_define_type( 1, "BOOLEAN", pg_type_enc_binary_boolean, pg_type_dec_binary_boolean, 16 );
	pg_type_define_type( 1, "BYTEA", pg_type_enc_to_str, pg_type_dec_binary_bytea, 17 );
	pg_type_define_type( 1, "INT8", pg_type_enc_binary_int8, pg_type_dec_binary_integer, 20 );
	pg_type_define_type( 1, "INT2", pg_type_enc_binary_int2, pg_type_dec_binary_integer, 21 );
	pg_type_define_type( 1, "INT4", pg_type_enc_binary_int4, pg_type_dec_binary_integer, 23 );
	pg_type_define_type( 1, "FLOAT4", NULL, pg_type_dec_binary_float, 700 );
	pg_type_define_type( 1, "FLOAT8", NULL, pg_type_dec_binary_float, 701 );
	pg_type_define_type( 1, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 25 );
	pg_type_define_type( 1, "VARCHAR", pg_type_enc_to_str, pg_type_dec_text_string, 1043 );

}
