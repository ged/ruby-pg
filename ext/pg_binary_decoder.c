/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_BinaryDecoder;
VALUE rb_cPG_BinaryDecoder_Simple;
VALUE rb_cPG_BinaryDecoder_Composite;


static VALUE
pg_bin_dec_boolean(t_pg_type *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	if (len < 1) {
		rb_raise( rb_eTypeError, "wrong data for binary boolean converter in tuple %d field %d", tuple, field);
	}
	return *val == 0 ? Qfalse : Qtrue;
}

static VALUE
pg_bin_dec_integer(t_pg_type *conv, char *val, int len, int tuple, int field, int enc_idx)
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
pg_bin_dec_float(t_pg_type *conv, char *val, int len, int tuple, int field, int enc_idx)
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
pg_bin_dec_bytea(t_pg_type *conv, char *val, int len, int tuple, int field, int enc_idx)
{
	VALUE ret;
	ret = rb_tainted_str_new( val, len );
#ifdef M17N_SUPPORTED
	rb_enc_associate( ret, rb_ascii8bit_encoding() );
#endif
	return ret;
}

static void
define_decoder( const char *name, t_pg_type_dec_func dec_func, VALUE klass, VALUE nsp )
{
  VALUE type_obj = Data_Wrap_Struct( klass, NULL, NULL, dec_func );
  rb_iv_set( type_obj, "@name", rb_obj_freeze(rb_str_new_cstr(name)) );
  rb_iv_set( type_obj, "@format", INT2NUM( 1 ));
  rb_iv_set( type_obj, "@direction", ID2SYM(rb_intern( "decoder" )));
  rb_define_const( nsp, name, type_obj );

  RB_GC_GUARD(type_obj);
}

void
init_pg_binary_decoder()
{
	rb_mPG_BinaryDecoder = rb_define_module_under( rb_mPG, "BinaryDecoder" );

	rb_cPG_BinaryDecoder_Simple = rb_define_class_under( rb_mPG_BinaryDecoder, "Simple", rb_cPG_Coder );
	define_decoder( "Boolean", pg_bin_dec_boolean, rb_cPG_BinaryDecoder_Simple, rb_mPG_BinaryDecoder );
	define_decoder( "Integer", pg_bin_dec_integer, rb_cPG_BinaryDecoder_Simple, rb_mPG_BinaryDecoder );
	define_decoder( "Float", pg_bin_dec_float, rb_cPG_BinaryDecoder_Simple, rb_mPG_BinaryDecoder );
	define_decoder( "String", pg_text_dec_string, rb_cPG_BinaryDecoder_Simple, rb_mPG_BinaryDecoder );
	define_decoder( "Bytea", pg_bin_dec_bytea, rb_cPG_BinaryDecoder_Simple, rb_mPG_BinaryDecoder );

	rb_cPG_BinaryDecoder_Composite = rb_define_class_under( rb_mPG_BinaryDecoder, "Composite", rb_cPG_Coder );
	rb_define_attr( rb_cPG_BinaryDecoder_Composite, "name", 1, 0 );
}
