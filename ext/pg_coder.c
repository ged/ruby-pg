/*
 * pg_coder.c - PG::Coder class extension
 *
 */

#include "pg.h"

VALUE rb_cPG_Coder;

void
pg_define_coder( const char *name, void *func, VALUE klass, VALUE nsp )
{
  VALUE type_obj = Data_Wrap_Struct( klass, NULL, NULL, func );
	VALUE objname = rb_str_dup(rb_mod_name(nsp));
	rb_str_cat2( objname, "::");
	rb_str_cat2( objname, name);

  rb_iv_set( type_obj, "@name", rb_obj_freeze(objname) );
  rb_define_const( nsp, name, rb_obj_freeze(type_obj) );

  RB_GC_GUARD(type_obj);
}

void
init_pg_coder()
{
	rb_cPG_Coder = rb_define_class_under( rb_mPG, "Coder", rb_cObject );
	rb_define_attr( rb_cPG_Coder, "name", 1, 0 );
}
