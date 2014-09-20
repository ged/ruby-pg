/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_BinaryDecoder;


static VALUE
pg_bin_dec_boolean(t_pg_coder *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for binary boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 0 ? Qfalse : Qtrue;
}

static VALUE
pg_bin_dec_integer(t_pg_coder *conv, char *val, int len, int tuple, int field, int enc_idx)
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
pg_bin_dec_float(t_pg_coder *conv, char *val, int len, int tuple, int field, int enc_idx)
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

VALUE
pg_bin_dec_bytea(t_pg_coder *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE ret;
	ret = rb_tainted_str_new( val, len );
#ifdef M17N_SUPPORTED
	ENCODING_SET( ret, rb_ascii8bit_encindex() );
#endif
	return ret;
}

void
init_pg_binary_decoder()
{
	rb_mPG_BinaryDecoder = rb_define_module_under( rb_mPG, "BinaryDecoder" );

	pg_define_coder( "Boolean", pg_bin_dec_boolean, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	pg_define_coder( "Integer", pg_bin_dec_integer, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	pg_define_coder( "Float", pg_bin_dec_float, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	pg_define_coder( "String", pg_text_dec_string, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
	pg_define_coder( "Bytea", pg_bin_dec_bytea, rb_cPG_SimpleDecoder, rb_mPG_BinaryDecoder );
}
