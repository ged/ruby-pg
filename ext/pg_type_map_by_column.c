/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

static VALUE rb_cTypeMapByColumn;
static ID s_id_decode;
static ID s_id_encode;

static VALUE
pg_tmbc_fit_to_result( VALUE self, VALUE result )
{
	int nfields;
	t_tmbc *this = DATA_PTR( self );

	nfields = PQnfields( pgresult_get(result) );
	if ( this->nfields != nfields ) {
		rb_raise( rb_eArgError, "number of result fields (%d) does not match number of mapped columns (%d)",
				nfields, this->nfields );
	}
	return self;
}

static VALUE
pg_tmbc_fit_to_query( VALUE self, VALUE params )
{
	int nfields;
	t_tmbc *this = DATA_PTR( self );

	nfields = (int)RARRAY_LEN( params );
	if ( this->nfields != nfields ) {
		rb_raise( rb_eArgError, "number of result fields (%d) does not match number of mapped columns (%d)",
				nfields, this->nfields );
	}
	return self;
}


VALUE
pg_tmbc_result_value(VALUE self, PGresult *result, int tuple, int field, t_typemap *p_typemap)
{
	VALUE ret;
	char * val;
	int len;
	t_tmbc *this = (t_tmbc *) p_typemap;
	t_pg_coder *conv = NULL;

	if (PQgetisnull(result, tuple, field)) {
		return Qnil;
	}

	val = PQgetvalue( result, tuple, field );
	len = PQgetlength( result, tuple, field );

	if( this ){
		conv = this->convs[field].cconv;

		if( conv && conv->dec_func ){
			return conv->dec_func(conv, val, len, tuple, field, ENCODING_GET(self));
		}
	}

	if ( 0 == PQfformat(result, field) ) {
		ret = pg_text_dec_string(NULL, val, len, tuple, field, ENCODING_GET(self));
	} else {
		ret = pg_bin_dec_bytea(NULL, val, len, tuple, field, ENCODING_GET(self));
	}

	if( conv ){
		ret = rb_funcall( conv->coder_obj, s_id_decode, 3, ret, INT2NUM(tuple), INT2NUM(field) );
	}

	return ret;
}

static t_pg_coder *
pg_tmbc_typecast_query_param(VALUE self, VALUE param_value, int field)
{
	t_tmbc *this = (t_tmbc *)DATA_PTR(self);

	return this->convs[field].cconv;
}

const t_typemap pg_tmbc_default_typemap = {
	fit_to_result: pg_tmbc_fit_to_result,
	fit_to_query: pg_tmbc_fit_to_query,
	typecast_result_value: pg_tmbc_result_value,
	typecast_query_param: pg_tmbc_typecast_query_param
};

static void
pg_tmbc_mark( t_tmbc *this )
{
	int i;

	/* allocated but not initialized ? */
	if( !this ) return;

	for( i=0; i<this->nfields; i++){
		t_pg_coder *p_coder = this->convs[i].cconv;
		if( p_coder )
			rb_gc_mark(p_coder->coder_obj);
	}
}

static VALUE
pg_tmbc_s_allocate( VALUE klass )
{
	return Data_Wrap_Struct( klass, pg_tmbc_mark, -1, NULL );
}

VALUE
pg_tmbc_allocate()
{
	return pg_tmbc_s_allocate(rb_cTypeMapByColumn);
}

static VALUE
pg_tmbc_init(VALUE self, VALUE conv_ary)
{
	int i;
	t_tmbc *this;
	int conv_ary_len;

	Check_Type(self, T_DATA);
	Check_Type(conv_ary, T_ARRAY);
	conv_ary_len = RARRAY_LEN(conv_ary);
	this = xmalloc(sizeof(t_tmbc) + sizeof(struct pg_tmbc_converter) * conv_ary_len);
	/* Set nfields to 0 at first, so that GC mark function doesn't access uninitialized memory. */
	this->nfields = 0;
	this->typemap = pg_tmbc_default_typemap;
	DATA_PTR(self) = this;

	for(i=0; i<conv_ary_len; i++)
	{
		VALUE obj = rb_ary_entry(conv_ary, i);

		if( obj == Qnil ){
			/* no type cast */
			this->convs[i].cconv = NULL;
		} else if( rb_obj_is_kind_of(obj, rb_cPG_Coder) ){
			Data_Get_Struct(obj, t_pg_coder, this->convs[i].cconv);
		} else {
			rb_raise(rb_eArgError, "argument %d has invalid type %s (should be nil or some kind of PG::Coder)",
							 i+1, rb_obj_classname( obj ));
		}
	}

	this->nfields = conv_ary_len;

	return self;
}

static VALUE
pg_tmbc_coders(VALUE self)
{
	int i;
	t_tmbc *this = DATA_PTR( self );
	VALUE ary_coders = rb_ary_new();

	for( i=0; i<this->nfields; i++){
		t_pg_coder *conv = this->convs[i].cconv;
		if( conv ) {
			rb_ary_push( ary_coders, conv->coder_obj );
		} else {
			rb_ary_push( ary_coders, Qnil );
		}
	}

	return rb_obj_freeze(ary_coders);
}

void
init_pg_type_map_by_column()
{
	s_id_decode = rb_intern("decode");
	s_id_encode = rb_intern("encode");

	rb_cTypeMapByColumn = rb_define_class_under( rb_mPG, "TypeMapByColumn", rb_cTypeMap );
	rb_define_alloc_func( rb_cTypeMapByColumn, pg_tmbc_s_allocate );
	rb_define_method( rb_cTypeMapByColumn, "initialize", pg_tmbc_init, 1 );
	rb_define_method( rb_cTypeMapByColumn, "coders", pg_tmbc_coders, 0 );
}
