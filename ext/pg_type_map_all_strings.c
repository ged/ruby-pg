/*
 * pg_type_map_all_strings.c - PG::TypeMapAllStrings class extension
 * $Id$
 *
 * This is the default typemap.
 *
 */

#include "pg.h"

VALUE rb_cTypeMapAllStrings;
VALUE pg_default_typemap;
static VALUE sym_type, sym_format;

static VALUE
pg_tmas_fit_to_result( VALUE self, VALUE result )
{
	return self;
}

static VALUE
pg_tmas_result_value(VALUE self, PGresult *result, int tuple, int field, t_typemap *p_typemap)
{
	VALUE ret;
	char * val;
	int len;

	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

	val = PQgetvalue( result, tuple, field );
	len = PQgetlength( result, tuple, field );

	if ( 0 == PQfformat(result, field) ) {
		ret = pg_text_dec_string(NULL, val, len, tuple, field, ENCODING_GET(self));
	} else {
		ret = pg_bin_dec_bytea(NULL, val, len, tuple, field, ENCODING_GET(self));
	}

	return ret;
}

static VALUE
pg_tmas_fit_to_query( VALUE self, VALUE params )
{
	return self;
}

static t_pg_coder *
pg_tmas_typecast_query_param(VALUE self, VALUE param_value, int field, int *p_format, Oid *p_type)
{
	if (TYPE(param_value) == T_HASH) {
		if( p_format ){
			VALUE format_value = rb_hash_aref(param_value, sym_format);
			if( !NIL_P(format_value) )
				*p_format = NUM2INT(format_value);
		}
		if( p_type ){
			VALUE type_value = rb_hash_aref(param_value, sym_type);
			if( !NIL_P(type_value) )
				*p_type = NUM2UINT(type_value);
		}
	}
	return NULL;
}

static int
pg_tmas_fit_to_copy_get( VALUE self )
{
	/* We can not predict the number of columns for copy */
	return 0;
}

static VALUE
pg_tmas_typecast_copy_get( t_typemap *p_typemap, VALUE field_str, int fieldno, int format, int enc_idx )
{
	if( format == 0 ){
		PG_ENCODING_SET_NOCHECK( field_str, enc_idx );
	} else {
		PG_ENCODING_SET_NOCHECK( field_str, rb_ascii8bit_encindex() );
	}
	return field_str;
}

static VALUE
pg_tmas_s_allocate( VALUE klass )
{
	t_typemap *this;
	VALUE self;

	self = Data_Make_Struct( klass, t_typemap, NULL, -1, this );

	this->fit_to_result = pg_tmas_fit_to_result;
	this->fit_to_query = pg_tmas_fit_to_query;
	this->fit_to_copy_get = pg_tmas_fit_to_copy_get;
	this->typecast_result_value = pg_tmas_result_value;
	this->typecast_query_param = pg_tmas_typecast_query_param;
	this->typecast_copy_get = pg_tmas_typecast_copy_get;

	return self;
}


void
init_pg_type_map_all_strings()
{
	sym_type = ID2SYM(rb_intern("type"));
	sym_format = ID2SYM(rb_intern("format"));

	rb_cTypeMapAllStrings = rb_define_class_under( rb_mPG, "TypeMapAllStrings", rb_cTypeMap );
	rb_define_alloc_func( rb_cTypeMapAllStrings, pg_tmas_s_allocate );

	pg_default_typemap = rb_funcall( rb_cTypeMapAllStrings, rb_intern("new"), 0 );
	rb_gc_register_address( &pg_default_typemap );
}
