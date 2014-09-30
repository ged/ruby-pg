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

static int
pg_tmbc_fit_to_copy_get( VALUE self )
{
	t_tmbc *this = DATA_PTR( self );
	return this->nfields;
}


VALUE
pg_tmbc_result_value(VALUE result, int tuple, int field)
{
	char * val;
	int len;
	t_pg_coder *p_coder = NULL;
	t_pg_coder_dec_func dec_func;
	t_pg_result *p_result = pgresult_get_this(result);
	t_tmbc *this = (t_tmbc *) p_result->p_typemap;

	if (PQgetisnull(p_result->pgresult, tuple, field)) {
		return Qnil;
	}

	val = PQgetvalue( p_result->pgresult, tuple, field );
	len = PQgetlength( p_result->pgresult, tuple, field );

	if( this ){
		p_coder = this->convs[field].cconv;

		if( p_coder && p_coder->dec_func ){
			return p_coder->dec_func(p_coder, val, len, tuple, field, ENCODING_GET(result));
		}
	}

	dec_func = pg_coder_dec_func( p_coder, PQfformat(p_result->pgresult, field) );
	return dec_func( p_coder, val, len, tuple, field, ENCODING_GET(result) );
}

static t_pg_coder *
pg_tmbc_typecast_query_param(VALUE self, VALUE param_value, int field, int *p_format, Oid *p_type)
{
	t_tmbc *this = (t_tmbc *)DATA_PTR(self);

	/* Number of fields were already checked in pg_tmbc_fit_to_query() */
	t_pg_coder *p_coder = this->convs[field].cconv;

	if( p_format && p_coder )
		*p_format = p_coder->format;
	if( p_type && p_coder )
		*p_type = p_coder->oid;

	return p_coder;
}

static VALUE
pg_tmbc_typecast_copy_get( t_typemap *p_typemap, VALUE field_str, int fieldno, int format, int enc_idx )
{
	t_tmbc *this = (t_tmbc *) p_typemap;
	t_pg_coder *p_coder;
	t_pg_coder_dec_func dec_func;

	if ( fieldno >= this->nfields || fieldno < 0 ) {
		rb_raise( rb_eArgError, "number of copy fields (%d) exceeds number of mapped columns (%d)",
				fieldno, this->nfields );
	}

	p_coder = this->convs[fieldno].cconv;

	dec_func = pg_coder_dec_func( p_coder, format );

	/* Is it a pure String conversion? Then we can directly send field_str to the user. */
	if( format == 0 && dec_func == pg_text_dec_string ){
		PG_ENCODING_SET_NOCHECK( field_str, enc_idx );
		return field_str;
	}
	if( format == 1 && dec_func == pg_bin_dec_bytea ){
		PG_ENCODING_SET_NOCHECK( field_str, rb_ascii8bit_encindex() );
		return field_str;
	}

	return dec_func( p_coder, RSTRING_PTR(field_str), RSTRING_LEN(field_str), 0, fieldno, enc_idx );
}

const t_typemap pg_tmbc_default_typemap = {
	fit_to_result: pg_tmbc_fit_to_result,
	fit_to_query: pg_tmbc_fit_to_query,
	fit_to_copy_get: pg_tmbc_fit_to_copy_get,
	typecast_result_value: pg_tmbc_result_value,
	typecast_query_param: pg_tmbc_typecast_query_param,
	typecast_copy_get: pg_tmbc_typecast_copy_get
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
