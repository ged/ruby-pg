/*
 * pg_type_map_by_mri_type.c - PG::TypeMapByMriType class extension
 * $Id$
 *
 */

#include "pg.h"

static VALUE rb_cTypeMapByMriType;
static ID s_id_encode;

#define FOR_EACH_MRI_TYPE(func) \
	func(T_NIL) \
	func(T_OBJECT) \
	func(T_CLASS) \
	func(T_MODULE) \
	func(T_FLOAT) \
	func(T_STRING) \
	func(T_REGEXP) \
	func(T_ARRAY) \
	func(T_HASH) \
	func(T_STRUCT) \
	func(T_BIGNUM) \
	func(T_FIXNUM) \
	func(T_COMPLEX) \
	func(T_RATIONAL) \
	func(T_FILE) \
	func(T_TRUE) \
	func(T_FALSE) \
	func(T_DATA) \
	func(T_SYMBOL)

#define DECLARE_CODER(type) t_pg_coder *coder_##type;

typedef struct {
	t_typemap typemap;
	struct pg_tmbmt_converter {
		FOR_EACH_MRI_TYPE( DECLARE_CODER );
	} coders;
} t_tmbmt;


#define CASE_AND_GET(type) \
	case type: \
		conv = this->coders.coder_##type; \
		break;

static VALUE
pg_tmbmt_alloc_query_params(VALUE _paramsData)
{
	struct query_params_data *paramsData = (struct query_params_data *)_paramsData;
	VALUE param_value;
	int param_type, param_format;
	VALUE param_mapping;
	int nParams;
	int i=0;
	t_tmbmt *this = (t_tmbmt *)paramsData->p_typemap;
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

			switch(TYPE(param_value)){
					FOR_EACH_MRI_TYPE( CASE_AND_GET )
				default:
					/* unknown MRI type */
					conv = NULL;
			}

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

			switch(TYPE(param_value)){
					FOR_EACH_MRI_TYPE( CASE_AND_GET )
				default:
					/* unknown MRI type */
					conv = NULL;
			}

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

static VALUE
pg_tmbmt_result_value(VALUE self, PGresult *result, int tuple, int field, t_typemap *p_typemap)
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map result values", RSTRING_PTR(rb_inspect(self)) );
	return Qnil;
}

static VALUE
pg_tmbmt_fit_to_query( VALUE params, VALUE self )
{
	return self;
}

static VALUE
pg_tmbmt_fit_to_result( VALUE result, VALUE self )
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map result values", RSTRING_PTR(rb_inspect(self)) );
	return self;
}

#define GC_MARK_AS_USED(type) \
	if(this->coders.coder_##type) rb_gc_mark(this->coders.coder_##type->coder_obj);

static void
pg_tmbmt_mark( t_tmbmt *this )
{
	FOR_EACH_MRI_TYPE( GC_MARK_AS_USED );
}

static VALUE
pg_tmbmt_s_allocate( VALUE klass )
{
	t_tmbmt *this;
	return Data_Make_Struct( klass, t_tmbmt, pg_tmbmt_mark, -1, this );
}

static VALUE
pg_tmbmt_init( VALUE self )
{
	t_tmbmt *this = DATA_PTR( self );

	this->typemap.fit_to_result = pg_tmbmt_fit_to_result;
	this->typemap.fit_to_query = pg_tmbmt_fit_to_query;
	this->typemap.typecast = pg_tmbmt_result_value;
	this->typemap.alloc_query_params = pg_tmbmt_alloc_query_params;

	return self;
}

#define COMPARE_AND_ASSIGN(type) \
	else if(!strcmp(p_mri_type, #type)){ \
		if(NIL_P(coder)){ \
			this->coders.coder_##type = NULL; \
		}else{ \
			Data_Get_Struct(coder, t_pg_coder, this->coders.coder_##type); \
		} \
	}

static VALUE
pg_tmbmt_aset( VALUE self, VALUE mri_type, VALUE coder )
{
	t_tmbmt *this = DATA_PTR( self );
	char *p_mri_type;

	if( !NIL_P(coder) && !rb_obj_is_kind_of(coder, rb_cPG_Coder) )
		rb_raise(rb_eArgError, "invalid type %s (should be nil or some kind of PG::Coder)",
							rb_obj_classname( coder ));

	p_mri_type = StringValueCStr(mri_type);

	if(0){}
	FOR_EACH_MRI_TYPE( COMPARE_AND_ASSIGN )
	else{
		rb_raise(rb_eArgError, "unknown mri_type %s", RSTRING_PTR(rb_inspect( mri_type )));
	}

	return self;
}

#define COMPARE_AND_GET(type) \
	else if(!strcmp(p_mri_type, #type)){ \
		coder = this->coders.coder_##type ? this->coders.coder_##type->coder_obj : Qnil; \
	}

static VALUE
pg_tmbmt_aref( VALUE self, VALUE mri_type )
{
	VALUE coder;
	t_tmbmt *this = DATA_PTR( self );
	char *p_mri_type;

	p_mri_type = StringValuePtr(mri_type);

	if(0){}
	FOR_EACH_MRI_TYPE( COMPARE_AND_GET )
	else{
		rb_raise(rb_eArgError, "unknown mri_type %s", RSTRING_PTR(rb_inspect( mri_type )));
	}

	return coder;
}

#define ADD_TO_HASH(type) \
	rb_hash_aset( hash_coders, rb_obj_freeze(rb_str_new2(#type)), this->coders.coder_##type ? this->coders.coder_##type->coder_obj : Qnil );


static VALUE
pg_tmbmt_coders( VALUE self )
{
	t_tmbmt *this = DATA_PTR( self );
	VALUE hash_coders = rb_hash_new();

	FOR_EACH_MRI_TYPE( ADD_TO_HASH );

	return rb_obj_freeze(hash_coders);
}

void
init_pg_type_map_by_mri_type()
{
	s_id_encode = rb_intern("encode");

	rb_cTypeMapByMriType = rb_define_class_under( rb_mPG, "TypeMapByMriType", rb_cTypeMap );
	rb_define_alloc_func( rb_cTypeMapByMriType, pg_tmbmt_s_allocate );
	rb_define_method( rb_cTypeMapByMriType, "initialize", pg_tmbmt_init, 0 );
	rb_define_method( rb_cTypeMapByMriType, "[]=", pg_tmbmt_aset, 2 );
	rb_define_method( rb_cTypeMapByMriType, "[]", pg_tmbmt_aref, 1 );
	rb_define_method( rb_cTypeMapByMriType, "coders", pg_tmbmt_coders, 0 );
}
