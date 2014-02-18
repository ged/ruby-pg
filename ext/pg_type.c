/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"

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


static int
pg_type_enc_not_implemented(VALUE value, char *out, VALUE *intermediate)
{
	rb_raise( rb_eArgError, "no encoder defined for %+i", value );
	return 0;
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

	type_obj = Data_Make_Struct( rb_cPG_Type_CConverter, struct pg_type_cconverter, NULL, -1, sval );
	sval->enc_func = enc_func;
	sval->dec_func = dec_func;
	sval->oid = oid;
	sval->format = format;
	rb_iv_set( type_obj, "@name", rb_obj_freeze(rb_str_new_cstr(name)) );

	rb_define_const( cFormatModule, name, type_obj );
}


void
init_pg_type()
{
	rb_mPG_Type = rb_define_module_under( rb_mPG, "Type" );
	rb_cPG_Type_CConverter = rb_define_class_under( rb_mPG_Type, "CConverter", rb_cObject );
	rb_define_method( rb_cPG_Type_CConverter, "encode", pg_type_encode, 1 );
	rb_define_method( rb_cPG_Type_CConverter, "decode", pg_type_decode, -1 );
	rb_define_method( rb_cPG_Type_CConverter, "oid", pg_type_oid, 0 );
	rb_define_method( rb_cPG_Type_CConverter, "format", pg_type_format, 0 );
	rb_define_attr( rb_cPG_Type_CConverter, "name", 1, 0 );
	rb_mPG_Type_Text = rb_define_module_under( rb_mPG_Type, "Text" );
	rb_mPG_Type_Binary = rb_define_module_under( rb_mPG_Type, "Binary" );

	pg_type_define_type( 0, "BOOLEAN", pg_type_enc_to_str, pg_type_dec_text_boolean, 16 );
	pg_type_define_type( 0, "BYTEA", pg_type_enc_to_str, pg_type_dec_text_bytea, 17 );
	pg_type_define_type( 0, "INT8", pg_type_enc_to_str, pg_type_dec_text_integer, 20 );
	pg_type_define_type( 0, "INT2", pg_type_enc_to_str, pg_type_dec_text_integer, 21 );
	pg_type_define_type( 0, "INT4", pg_type_enc_to_str, pg_type_dec_text_integer, 23 );
	pg_type_define_type( 0, "FLOAT4", pg_type_enc_to_str, pg_type_dec_text_float, 700 );
	pg_type_define_type( 0, "FLOAT8", pg_type_enc_to_str, pg_type_dec_text_float, 701 );
	pg_type_define_type( 0, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 25 );

	pg_type_define_type( 1, "BOOLEAN", pg_type_enc_binary_boolean, pg_type_dec_binary_boolean, 16 );
	pg_type_define_type( 1, "BYTEA", pg_type_enc_to_str, pg_type_dec_binary_bytea, 17 );
	pg_type_define_type( 1, "INT8", pg_type_enc_binary_int8, pg_type_dec_binary_integer, 20 );
	pg_type_define_type( 1, "INT2", pg_type_enc_binary_int2, pg_type_dec_binary_integer, 21 );
	pg_type_define_type( 1, "INT4", pg_type_enc_binary_int4, pg_type_dec_binary_integer, 23 );
	pg_type_define_type( 1, "FLOAT4", pg_type_enc_not_implemented, pg_type_dec_binary_float, 700 );
	pg_type_define_type( 1, "FLOAT8", pg_type_enc_not_implemented, pg_type_dec_binary_float, 701 );
	pg_type_define_type( 1, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 25 );
}
