/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_Type_BinaryEncoder;
VALUE rb_cPG_Type_BinaryEncoder_Simple;
VALUE rb_cPG_Type_BinaryEncoder_Composite;

/* encoders usable for both text and binary formats */
extern int pg_type_enc_to_str(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate);


static int
pg_type_enc_binary_boolean(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
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
pg_type_enc_binary_int2(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int16_t*)out = htobe16(NUM2INT(value));
	return 2;
}

static int
pg_type_enc_binary_int4(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int32_t*)out = htobe32(NUM2LONG(value));
	return 4;
}

static int
pg_type_enc_binary_int8(t_pg_type *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out) *(int64_t*)out = htobe64(NUM2LL(value));
	return 8;
}

static void
define_encoder( const char *name, t_pg_type_enc_func enc_func, VALUE klass, VALUE nsp )
{
  VALUE type_obj = Data_Wrap_Struct( klass, NULL, NULL, enc_func );
  rb_iv_set( type_obj, "@name", rb_obj_freeze(rb_str_new_cstr(name)) );
  rb_define_const( nsp, name, type_obj );

  RB_GC_GUARD(type_obj);
}

void
init_pg_type_binary_encoder()
{
	rb_mPG_Type_BinaryEncoder = rb_define_module_under( rb_mPG_Type, "BinaryEncoder" );

	rb_cPG_Type_BinaryEncoder_Simple = rb_define_class_under( rb_mPG_Type_BinaryEncoder, "Simple", rb_cObject );
	rb_define_attr( rb_cPG_Type_BinaryEncoder_Simple, "name", 1, 0 );
	define_encoder( "Boolean", pg_type_enc_binary_boolean, rb_cPG_Type_BinaryEncoder_Simple, rb_mPG_Type_BinaryEncoder );
	define_encoder( "Int2", pg_type_enc_binary_int2, rb_cPG_Type_BinaryEncoder_Simple, rb_mPG_Type_BinaryEncoder );
	define_encoder( "Int4", pg_type_enc_binary_int4, rb_cPG_Type_BinaryEncoder_Simple, rb_mPG_Type_BinaryEncoder );
	define_encoder( "Int8", pg_type_enc_binary_int8, rb_cPG_Type_BinaryEncoder_Simple, rb_mPG_Type_BinaryEncoder );
	define_encoder( "Bytea", pg_type_enc_to_str, rb_cPG_Type_BinaryEncoder_Simple, rb_mPG_Type_BinaryEncoder );

	rb_cPG_Type_BinaryEncoder_Composite = rb_define_class_under( rb_mPG_Type_BinaryEncoder, "Composite", rb_cObject );
	rb_define_attr( rb_cPG_Type_BinaryEncoder_Composite, "name", 1, 0 );
}
