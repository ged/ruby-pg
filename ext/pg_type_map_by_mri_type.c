/*
 * pg_type_map_by_mri_type.c - PG::TypeMapByMriType class extension
 * $Id$
 *
 */

#include "pg.h"

static VALUE rb_cTypeMapByMriType;

#define FOR_EACH_MRI_TYPE(func) \
	func(T_FIXNUM) \
	func(T_TRUE) \
	func(T_FALSE) \
	func(T_FLOAT) \
	func(T_BIGNUM) \
	func(T_COMPLEX) \
	func(T_RATIONAL) \
	func(T_ARRAY) \
	func(T_STRING) \
	func(T_SYMBOL) \
	func(T_OBJECT) \
	func(T_CLASS) \
	func(T_MODULE) \
	func(T_REGEXP) \
	func(T_HASH) \
	func(T_STRUCT) \
	func(T_FILE) \
	func(T_DATA)

#define DECLARE_CODER(type) \
	t_pg_coder *coder_##type; \
	VALUE ask_##type;

typedef struct {
	t_typemap typemap;
	struct pg_tmbmt_converter {
		FOR_EACH_MRI_TYPE( DECLARE_CODER );
	} coders;
} t_tmbmt;


#define CASE_AND_GET(type) \
	case type: \
		conv = this->coders.coder_##type; \
		ask_for_coder = this->coders.ask_##type; \
		break;

static t_pg_coder *
pg_tmbmt_typecast_query_param(VALUE self, VALUE param_value, int field)
{
	t_tmbmt *this = (t_tmbmt *)DATA_PTR(self);
	t_pg_coder *conv;
	VALUE ask_for_coder;

	switch(TYPE(param_value)){
			FOR_EACH_MRI_TYPE( CASE_AND_GET )
		default:
			/* unknown MRI type */
			conv = NULL;
			ask_for_coder = Qnil;
	}

	if( !NIL_P(ask_for_coder) ){
		/* No static Coder object, but proc/method given to ask for the Coder to use. */
		VALUE obj;

		if( TYPE(ask_for_coder) == T_SYMBOL ){
			obj = rb_funcall(self, SYM2ID(ask_for_coder), 1, param_value);
		}else{
			obj = rb_funcall(ask_for_coder, rb_intern("call"), 1, param_value);
		}

		if( rb_obj_is_kind_of(obj, rb_cPG_Coder) ){
			Data_Get_Struct(obj, t_pg_coder, conv);
		}else{
			rb_raise(rb_eTypeError, "argument %d has invalid type %s (should be nil or some kind of PG::Coder)",
						field+1, rb_obj_classname( obj ));
		}
	}
	return conv;
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
	if(this->coders.coder_##type) rb_gc_mark(this->coders.coder_##type->coder_obj); \
	rb_gc_mark( this->coders.ask_##type );

static void
pg_tmbmt_mark( t_tmbmt *this )
{
	FOR_EACH_MRI_TYPE( GC_MARK_AS_USED );
}

#define INIT_VARIABLES(type) \
	this->coders.coder_##type = NULL; \
	this->coders.ask_##type = Qnil;

static VALUE
pg_tmbmt_s_allocate( VALUE klass )
{
	t_tmbmt *this;
	VALUE self;

	self = Data_Make_Struct( klass, t_tmbmt, pg_tmbmt_mark, -1, this );
	this->typemap.fit_to_result = pg_tmbmt_fit_to_result;
	this->typemap.fit_to_query = pg_tmbmt_fit_to_query;
	this->typemap.typecast_result_value = pg_tmbmt_result_value;
	this->typemap.typecast_query_param = pg_tmbmt_typecast_query_param;

	FOR_EACH_MRI_TYPE( INIT_VARIABLES );

	return self;
}

#define COMPARE_AND_ASSIGN(type) \
	else if(!strcmp(p_mri_type, #type)){ \
		if(NIL_P(coder)){ \
			this->coders.coder_##type = NULL; \
			this->coders.ask_##type = Qnil; \
		}else if(rb_obj_is_kind_of(coder, rb_cPG_Coder)){ \
			Data_Get_Struct(coder, t_pg_coder, this->coders.coder_##type); \
			this->coders.ask_##type = Qnil; \
		}else{ \
			this->coders.coder_##type = NULL; \
			this->coders.ask_##type = coder; \
		} \
	}

static VALUE
pg_tmbmt_aset( VALUE self, VALUE mri_type, VALUE coder )
{
	t_tmbmt *this = DATA_PTR( self );
	char *p_mri_type;

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
		coder = this->coders.coder_##type ? this->coders.coder_##type->coder_obj : this->coders.ask_##type; \
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
	rb_hash_aset( hash_coders, rb_obj_freeze(rb_str_new2(#type)), this->coders.coder_##type ? this->coders.coder_##type->coder_obj : this->coders.ask_##type );


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
	rb_cTypeMapByMriType = rb_define_class_under( rb_mPG, "TypeMapByMriType", rb_cTypeMap );
	rb_define_alloc_func( rb_cTypeMapByMriType, pg_tmbmt_s_allocate );
	rb_define_method( rb_cTypeMapByMriType, "[]=", pg_tmbmt_aset, 2 );
	rb_define_method( rb_cTypeMapByMriType, "[]", pg_tmbmt_aref, 1 );
	rb_define_method( rb_cTypeMapByMriType, "coders", pg_tmbmt_coders, 0 );
}
