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
pg_type_dec_text_boolean(VALUE self, PGresult *result, int tuple, int field)
{
	if (PQgetlength(result, tuple, field) < 1) {
		rb_raise( rb_eTypeError, "wrong data for text boolean converter in tuple %d field %d", tuple, field);
	}
	return *PQgetvalue(result, tuple, field) == 't' ? Qtrue : Qfalse;
}

static VALUE
pg_type_dec_binary_boolean(VALUE self, PGresult *result, int tuple, int field)
{
	if (PQgetlength(result, tuple, field) < 1) {
		rb_raise( rb_eTypeError, "wrong data for binary boolean converter in tuple %d field %d", tuple, field);
	}
	return *PQgetvalue(result, tuple, field) == 0 ? Qfalse : Qtrue;
}

static VALUE
pg_type_dec_text_string(VALUE self, PGresult *result, int tuple, int field)
{
	VALUE val;
	val = rb_tainted_str_new( PQgetvalue(result, tuple, field ),
	                          PQgetlength(result, tuple, field) );
#ifdef M17N_SUPPORTED
	ASSOCIATE_INDEX( val, self );
#endif
	return val;
}

static VALUE
pg_type_dec_text_integer(VALUE self, PGresult *result, int tuple, int field)
{
	return rb_cstr2inum(PQgetvalue(result, tuple, field), 10);
}

static VALUE
pg_type_dec_binary_integer(VALUE self, PGresult *result, int tuple, int field)
{
	int len;
	len = PQgetlength(result, tuple, field);
	switch( len ){
		case 2:
			return INT2NUM((int16_t)be16toh(*(int16_t*)PQgetvalue(result, tuple, field)));
		case 4:
			return LONG2NUM((int32_t)be32toh(*(int32_t*)PQgetvalue(result, tuple, field)));
		case 8:
			return LL2NUM((int64_t)be64toh(*(int64_t*)PQgetvalue(result, tuple, field)));
		default:
			rb_raise( rb_eTypeError, "wrong data for binary integer converter in tuple %d field %d length %d", tuple, field, len);
	}
}

static VALUE
pg_type_dec_text_float(VALUE self, PGresult *result, int tuple, int field)
{
	return rb_float_new(strtod(PQgetvalue(result, tuple, field), NULL));
}

static VALUE
pg_type_dec_binary_float(VALUE self, PGresult *result, int tuple, int field)
{
	int len;
	union {
		float f;
		int32_t i;
	} swap4;
	union {
		double f;
		int64_t i;
	} swap8;

	len = PQgetlength(result, tuple, field);
	switch( len ){
		case 4:
			swap4.f = *(float *)PQgetvalue(result, tuple, field);
			swap4.i = be32toh(swap4.i);
			return rb_float_new(swap4.f);
		case 8:
			swap8.f = *(double *)PQgetvalue(result, tuple, field);
			swap8.i = be64toh(swap8.i);
			return rb_float_new(swap8.f);
		default:
			rb_raise( rb_eTypeError, "wrong data for BinaryFloat converter in tuple %d field %d length %d", tuple, field, len);
	}
}

static VALUE
pg_type_dec_text_bytea(VALUE self, PGresult *result, int tuple, int field)
{
	unsigned char *to;
	size_t to_len;
	VALUE ret;

	to = PQunescapeBytea( (unsigned char *)PQgetvalue(result, tuple, field ), &to_len);

	ret = rb_tainted_str_new((char*)to, to_len);
	PQfreemem(to);

	return ret;
}

static VALUE
pg_type_dec_binary_bytea(VALUE self, PGresult *result, int tuple, int field)
{
	VALUE val;
	val = rb_tainted_str_new( PQgetvalue(result, tuple, field ),
	                          PQgetlength(result, tuple, field) );
#ifdef M17N_SUPPORTED
	rb_enc_associate( val, rb_ascii8bit_encoding() );
#endif
	return val;
}

VALUE
pg_type_dec_text_or_binary_string(VALUE self, PGresult *result, int tuple, int field)
{
	if ( 0 == PQfformat(result, field) ) {
		return pg_type_dec_text_string(self, result, tuple, field);
	} else {
		return pg_type_dec_binary_bytea(self, result, tuple, field);
	}
}


VALUE
pg_type_enc_to_str(VALUE value)
{
	return rb_obj_as_string(value);
}


static VALUE
pg_type_encode(VALUE self, VALUE value)
{
	struct pg_type_cconverter *type_data = DATA_PTR(self);
	if( !type_data->enc_func ){
		rb_raise( rb_eArgError, "no encoder defined for type %s",
				rb_obj_classname( self ) );
	}
	return type_data->enc_func(value);
}

static VALUE
pg_type_decode(VALUE self, VALUE result, VALUE tuple, VALUE field, VALUE string)
{
	struct pg_type_cconverter *type_data = DATA_PTR(self);
	PGresult *p_result = pgresult_get(result);
	if( !type_data->dec_func ){
		rb_raise( rb_eArgError, "no decoder defined for type %s",
				rb_obj_classname( self ) );
	}
	return type_data->dec_func(result, p_result, NUM2INT(tuple), NUM2INT(field));
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

	rb_define_const( cFormatModule, name, type_obj );
}


void
init_pg_type()
{
	rb_mPG_Type = rb_define_module_under( rb_mPG, "Type" );
	rb_cPG_Type_CConverter = rb_define_class_under( rb_mPG_Type, "CConverter", rb_cObject );
	rb_define_method( rb_cPG_Type_CConverter, "encode", pg_type_encode, 1 );
	rb_define_method( rb_cPG_Type_CConverter, "decode", pg_type_decode, 4 );
	rb_define_method( rb_cPG_Type_CConverter, "oid", pg_type_oid, 0 );
	rb_define_method( rb_cPG_Type_CConverter, "format", pg_type_format, 0 );
	rb_mPG_Type_Text = rb_define_module_under( rb_mPG_Type, "Text" );
	rb_mPG_Type_Binary = rb_define_module_under( rb_mPG_Type, "Binary" );

	pg_type_define_type( 0, "BOOLEAN", pg_type_enc_to_str, pg_type_dec_text_boolean, 16 );
	pg_type_define_type( 0, "BYTEA", pg_type_enc_to_str, pg_type_dec_text_bytea, 17 );
	pg_type_define_type( 0, "INT8", pg_type_enc_to_str, pg_type_dec_text_integer, 20 );
	pg_type_define_type( 0, "INT2", pg_type_enc_to_str, pg_type_dec_text_integer, 21 );
	pg_type_define_type( 0, "INT4", pg_type_enc_to_str, pg_type_dec_text_integer, 23 );
	pg_type_define_type( 0, "FLOAT4", pg_type_enc_to_str, pg_type_dec_text_float, 700 );
	pg_type_define_type( 0, "FLOAT8", pg_type_enc_to_str, pg_type_dec_text_float, 701 );
	pg_type_define_type( 0, "TEXT", pg_type_enc_to_str, pg_type_dec_text_string, 705 );

	pg_type_define_type( 1, "BOOLEAN", NULL, pg_type_dec_binary_boolean, 16 );
	pg_type_define_type( 1, "BYTEA", NULL, pg_type_dec_binary_bytea, 17 );
	pg_type_define_type( 1, "INT8", NULL, pg_type_dec_binary_integer, 20 );
	pg_type_define_type( 1, "INT2", NULL, pg_type_dec_binary_integer, 21 );
	pg_type_define_type( 1, "INT4", NULL, pg_type_dec_binary_integer, 23 );
	pg_type_define_type( 1, "FLOAT4", NULL, pg_type_dec_binary_float, 700 );
	pg_type_define_type( 1, "FLOAT8", NULL, pg_type_dec_binary_float, 701 );
	pg_type_define_type( 1, "TEXT", NULL, pg_type_dec_text_string, 705 );
}
