/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

VALUE rb_cTypeMap;
static ID s_id_fit_to_query;
static ID s_id_fit_to_result;

static VALUE
pg_typemap_fit_to_result( VALUE result, VALUE self )
{
	VALUE new_typemap;
	new_typemap = rb_funcall( self, s_id_fit_to_result, 1, result );

	if ( !rb_obj_is_kind_of(new_typemap, rb_cTypeMap) ) {
		rb_raise( rb_eTypeError, "wrong return type from fit_to_result: %s expected kind of PG::TypeMap",
				rb_obj_classname( new_typemap ) );
	}
	Check_Type( new_typemap, T_DATA );

	return new_typemap;
}

static VALUE
pg_typemap_fit_to_query( VALUE params, VALUE self )
{
	VALUE new_typemap;
	new_typemap = rb_funcall( self, s_id_fit_to_query, 1, params );

	if ( !rb_obj_is_kind_of(new_typemap, rb_cTypeMap) ) {
		rb_raise( rb_eTypeError, "wrong return type from fit_to_query: %s expected kind of PG::TypeMap",
				rb_obj_classname( new_typemap ) );
	}
	Check_Type( new_typemap, T_DATA );

	return new_typemap;
}

static VALUE
pg_typemap_result_value(VALUE self, PGresult *result, int tuple, int field, t_typemap *p_typemap)
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map result values", RSTRING_PTR(rb_inspect(self)) );
	return Qnil;
}

static VALUE
pg_typemap_alloc_query_params(VALUE _paramsData)
{
	struct query_params_data *paramsData = (struct query_params_data *)_paramsData;
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map query params", RSTRING_PTR(rb_inspect(paramsData->param_mapping)) );
	return Qnil;
}

static VALUE
pg_typemap_s_allocate( VALUE klass )
{
	VALUE self;
	t_typemap *this;

	self = Data_Make_Struct( klass, t_typemap, NULL, -1, this );
	this->encoding_index = 0;
	this->fit_to_result = pg_typemap_fit_to_result;
	this->fit_to_query = pg_typemap_fit_to_query;
	this->typecast = pg_typemap_result_value;
	this->alloc_query_params = pg_typemap_alloc_query_params;

	return self;
}

void
init_pg_type_map()
{
	s_id_fit_to_query = rb_intern("fit_to_query");
	s_id_fit_to_result = rb_intern("fit_to_result");

	rb_cTypeMap = rb_define_class_under( rb_mPG, "TypeMap", rb_cObject );
	rb_define_alloc_func( rb_cTypeMap, pg_typemap_s_allocate );
}
