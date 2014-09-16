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
pg_tmbc_fit_to_result( VALUE result, VALUE typemap )
{
	int nfields;
	t_tmbc *this = DATA_PTR( typemap );

	nfields = PQnfields( DATA_PTR(result) );
	if ( this->nfields != nfields ) {
		rb_raise( rb_eArgError, "number of result fields (%d) does not match number of mapped columns (%d)",
				nfields, this->nfields );
	}
	return typemap;
}

static VALUE
pg_tmbc_fit_to_query( VALUE params, VALUE typemap )
{
	int nfields;
	t_tmbc *this = DATA_PTR( typemap );

	nfields = (int)RARRAY_LEN( params );
	if ( this->nfields != nfields ) {
		rb_raise( rb_eArgError, "number of result fields (%d) does not match number of mapped columns (%d)",
				nfields, this->nfields );
	}
	return typemap;
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
			return conv->dec_func(conv, val, len, tuple, field, this->typemap.encoding_index);
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

static VALUE
pg_tmbc_alloc_query_params(VALUE _paramsData)
{
	struct query_params_data *paramsData = (struct query_params_data *)_paramsData;
	VALUE param_value;
	int param_type, param_format;
	VALUE param_mapping;
	int nParams;
	int i=0;
	t_tmbc *this = (t_tmbc *)paramsData->p_typemap;
	t_pg_coder *conv;
	int sum_lengths = 0;
	int buffer_pos = 0;

	param_mapping = paramsData->param_mapping;
	nParams = (int)RARRAY_LEN(paramsData->params);
	if( paramsData->with_types )
		paramsData->types = ALLOC_N(Oid, nParams);
	paramsData->values = ALLOC_N(char *, nParams);
	paramsData->lengths = ALLOC_N(int, nParams);
	paramsData->formats = ALLOC_N(int, nParams);
	paramsData->param_values = ALLOC_N(VALUE, nParams);

	{
		VALUE intermediates[nParams];

		for ( i = 0; i < nParams; i++ ) {
			param_value = rb_ary_entry(paramsData->params, i);
			param_type = 0;
			param_format = 0;

			conv = this->convs[i].cconv;

			if( NIL_P(param_value) ){
				paramsData->values[i] = NULL;
				paramsData->lengths[i] = 0;
				if( conv )
					param_type = conv->oid;
			} else if( conv ) {
				if( conv->enc_func ){
					/* C-based converter */
					/* 1st pass for retiving the required memory space */
					int len = conv->enc_func(conv, param_value, NULL, &intermediates[i]);
					/* text format strings must be zero terminated */
					sum_lengths += len + (conv->format == 0 ? 1 : 0);
				} else {
					/* Ruby-based converter */
					param_value = rb_funcall( conv->coder_obj, s_id_encode, 1, param_value );
					rb_ary_push(paramsData->gc_array, param_value);
					paramsData->values[i] = RSTRING_PTR(param_value);
					paramsData->lengths[i] = (int)RSTRING_LEN(param_value);
				}

				param_type = conv->oid;
				param_format = conv->format;
			} else {
				param_value = rb_obj_as_string(param_value);
				/* make sure param_value doesn't get freed by the GC */
				rb_ary_push(paramsData->gc_array, param_value);
				paramsData->values[i] = RSTRING_PTR(param_value);
				paramsData->lengths[i] = (int)RSTRING_LEN(param_value);
			}

			if( paramsData->with_types ){
				paramsData->types[i] = param_type;
			}

			paramsData->formats[i] = param_format;
			paramsData->param_values[i] = param_value;
		}

		paramsData->mapping_buf = ALLOC_N(char, sum_lengths);

		for ( i = 0; i < nParams; i++ ) {
			param_value = paramsData->param_values[i];
			conv = this->convs[i].cconv;
			if( NIL_P(param_value) ){
				/* Qnil was mapped to NULL value above */
			} else if( conv && conv->enc_func ){
				/* 2nd pass for writing the data to prepared buffer */
				int len = conv->enc_func(conv, param_value, &paramsData->mapping_buf[buffer_pos], &intermediates[i]);
				paramsData->values[i] = &paramsData->mapping_buf[buffer_pos];
				paramsData->lengths[i] = len;
				if( conv->format == 0 ){
					/* text format strings must be zero terminated */
					paramsData->mapping_buf[buffer_pos+len] = 0;
					buffer_pos += len + 1;
				} else {
					buffer_pos += len;
				}
			}
		}
		RB_GC_GUARD_PTR(intermediates);
	}


	RB_GC_GUARD(param_mapping);

	return (VALUE)nParams;
}

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
	DATA_PTR(self) = this;

	/* encoding_index is set, when the TypeMapByColumn is assigned to a PG::Result. */
	this->nfields = conv_ary_len;
	this->typemap.encoding_index = 0;
	this->typemap.fit_to_result = pg_tmbc_fit_to_result;
	this->typemap.fit_to_query = pg_tmbc_fit_to_query;
	this->typemap.typecast = pg_tmbc_result_value;
	this->typemap.alloc_query_params = pg_tmbc_alloc_query_params;

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
