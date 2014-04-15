/*
 * pg_coder.c - PG::Coder class extension
 *
 */

#include "pg.h"

VALUE rb_cPG_Coder;

void
init_pg_coder()
{
	rb_cPG_Coder = rb_define_class_under( rb_mPG, "Coder", rb_cObject );
	rb_define_attr( rb_cPG_Coder, "name", 1, 0 );
	rb_define_attr( rb_cPG_Coder, "format", 1, 0 );
	rb_define_attr( rb_cPG_Coder, "direction", 1, 0 );
}
