/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"
#include "util.h"
#include <inttypes.h>

VALUE rb_mPG_BinaryEncoder;

/* encoders usable for both text and binary formats */
extern int pg_coder_enc_to_str(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate);


static int
pg_bin_enc_boolean(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
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
pg_bin_enc_int2(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		*(int16_t*)out = htobe16(NUM2INT(*intermediate));
	}else{
		*intermediate = pg_obj_to_i(value);
	}
	return 2;
}

static int
pg_bin_enc_int4(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		*(int32_t*)out = htobe32(NUM2LONG(*intermediate));
	}else{
		*intermediate = pg_obj_to_i(value);
	}
	return 4;
}

static int
pg_bin_enc_int8(t_pg_coder *conv, VALUE value, char *out, VALUE *intermediate)
{
	if(out){
		*(int64_t*)out = htobe64(NUM2LL(*intermediate));
	}else{
		*intermediate = pg_obj_to_i(value);
	}
	return 8;
}

void
init_pg_binary_encoder()
{
	rb_mPG_BinaryEncoder = rb_define_module_under( rb_mPG, "BinaryEncoder" );

	pg_define_coder( "Boolean", pg_bin_enc_boolean, rb_cPG_SimpleEncoder, rb_mPG_BinaryEncoder );
	pg_define_coder( "Int2", pg_bin_enc_int2, rb_cPG_SimpleEncoder, rb_mPG_BinaryEncoder );
	pg_define_coder( "Int4", pg_bin_enc_int4, rb_cPG_SimpleEncoder, rb_mPG_BinaryEncoder );
	pg_define_coder( "Int8", pg_bin_enc_int8, rb_cPG_SimpleEncoder, rb_mPG_BinaryEncoder );
	pg_define_coder( "String", pg_coder_enc_to_str, rb_cPG_SimpleEncoder, rb_mPG_BinaryEncoder );
	pg_define_coder( "Bytea", pg_coder_enc_to_str, rb_cPG_SimpleEncoder, rb_mPG_BinaryEncoder );
}
