/*
 * pg_column_map.c - PG::ColumnMap class extension
 * $Id$
 *
 */

#include "pg.h"

VALUE rb_cTypeMap;
static ID s_id_fit_to_query;
static ID s_id_fit_to_result;

VALUE
pg_typemap_fit_to_result( VALUE self, VALUE result )
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map result values", rb_obj_classname(self) );
	return Qnil;
}

VALUE
pg_typemap_fit_to_query( VALUE self, VALUE params )
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map query params", rb_obj_classname(self) );
	return Qnil;
}

int
pg_typemap_fit_to_copy_get( VALUE self )
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map copy_get_data results", rb_obj_classname(self) );
	return Qnil;
}

VALUE
pg_typemap_result_value(VALUE self, int tuple, int field)
{
	rb_raise( rb_eNotImpError, "type map is not suitable to map result values" );
	return Qnil;
}

t_pg_coder *
pg_typemap_typecast_query_param(VALUE self, VALUE param_value, int field)
{
	rb_raise( rb_eNotImpError, "type map %s is not suitable to map query params", rb_obj_classname(self) );
	return NULL;
}

VALUE
pg_typemap_typecast_copy_get( t_typemap *p_typemap, VALUE field_str, int fieldno, int format, int enc_idx )
{
	rb_raise( rb_eNotImpError, "type map is not suitable to map copy_get_data results" );
	return Qnil;
}

static VALUE
pg_typemap_s_allocate( VALUE klass )
{
	VALUE self;
	t_typemap *this;

	self = Data_Make_Struct( klass, t_typemap, NULL, -1, this );
	this->fit_to_result = pg_typemap_fit_to_result;
	this->fit_to_query = pg_typemap_fit_to_query;
	this->fit_to_copy_get = pg_typemap_fit_to_copy_get;
	this->typecast_result_value = pg_typemap_result_value;
	this->typecast_query_param = pg_typemap_typecast_query_param;
	this->typecast_copy_get = pg_typemap_typecast_copy_get;

	return self;
}

static VALUE
pg_typemap_fit_to_result_ext( VALUE self, VALUE result )
{
	t_typemap *this = DATA_PTR( self );

	if ( !rb_obj_is_kind_of(result, rb_cPGresult) ) {
		rb_raise( rb_eTypeError, "wrong argument type %s (expected kind of PG::Result)",
				rb_obj_classname( result ) );
	}

	return this->fit_to_result( self, result );
}

static VALUE
pg_typemap_fit_to_query_ext( VALUE self, VALUE params )
{
	t_typemap *this = DATA_PTR( self );

	Check_Type( params, T_ARRAY);

	return this->fit_to_query( self, params );
}

void
init_pg_type_map()
{
	s_id_fit_to_query = rb_intern("fit_to_query");
	s_id_fit_to_result = rb_intern("fit_to_result");

	/*
	 * Document-class: PG::TypeMap < Object
	 *
	 * This is the base class for type maps.
	 * See derived classes for implementations of different type cast strategies
	 * ( PG::TypeMapByColumn, PG::TypeMapByOid ).
	 *
	 */
	rb_cTypeMap = rb_define_class_under( rb_mPG, "TypeMap", rb_cObject );
	rb_define_alloc_func( rb_cTypeMap, pg_typemap_s_allocate );
	rb_define_method( rb_cTypeMap, "fit_to_result", pg_typemap_fit_to_result_ext, 1 );
	rb_define_method( rb_cTypeMap, "fit_to_query", pg_typemap_fit_to_query_ext, 1 );
}
