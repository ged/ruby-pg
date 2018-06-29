#include "pg.h"

static VALUE rb_cPG_VeryLazyTuple;

typedef struct {
	/* PG::Result object this tuple was retrieved from.
	 * Qnil when all fields are materialized.
	 */
	VALUE result;

	/* Store the typemap of the result.
	 * It's not enough to reference the PG::TypeMap object through the result,
	 * since it could be exchanged after the tuple has been created.
	 */
	VALUE typemap;

	/* Row number within the result set. */
	int row_num;
	/* Number of fields of this tuple. => Size of values[] */
	int num_fields;

	/* Materialized values. */
	VALUE values[0];
} t_pgvlt;

static void
pgvlt_gc_mark( t_pgvlt *this )
{
	int i;

	if( !this ) return;
	rb_gc_mark( this->result );
	rb_gc_mark( this->typemap );

	for( i = 0; i < this->num_fields; i++ ){
		rb_gc_mark( this->values[i] );
	}
}

static void
pgvlt_gc_free( t_pgvlt *this )
{
	if( !this ) return;
	xfree(this);
}

static size_t
pgvlt_memsize( t_pgvlt *this )
{
	return sizeof(*this) +  sizeof(*this->values) * this->num_fields;
}

static const rb_data_type_t pgvlt_type = {
	"pg",
	{
		(void (*)(void*))pgvlt_gc_mark,
		(void (*)(void*))pgvlt_gc_free,
		(size_t (*)(const void *))pgvlt_memsize,
	},
	0, 0,
#ifdef RUBY_TYPED_FREE_IMMEDIATELY
	RUBY_TYPED_FREE_IMMEDIATELY,
#endif
};

/*
 * Document-method: allocate
 *
 * call-seq:
 *   PG::VeryLazyTuple.allocate -> obj
 */
static VALUE
pgvlt_s_allocate( VALUE klass )
{
	return TypedData_Wrap_Struct( klass, &pgvlt_type, NULL );
}

VALUE
pgvlt_new(VALUE result, int row_num)
{
	t_pgvlt *this;
	VALUE self = pgvlt_s_allocate( rb_cPG_VeryLazyTuple );
	t_pg_result *p_result = pgresult_get_this(result);
	int num_fields = PQnfields(p_result->pgresult);
	int i;

	this = (t_pgvlt *)xmalloc(sizeof(*this) +  sizeof(*this->values) * num_fields);
	RTYPEDDATA_DATA(self) = this;

	this->result = result;
	this->typemap = p_result->typemap;
	this->row_num = row_num;
	this->num_fields = num_fields;

	for( i = 0; i < this->num_fields; i++ ){
		this->values[i] = Qundef;
	}

	return self;
}

static inline t_pgvlt *
pgvlt_get_this( VALUE self )
{
	t_pgvlt *this;
	TypedData_Get_Struct(self, t_pgvlt, &pgvlt_type, this);
	if (this == NULL)
		rb_raise(rb_eTypeError, "tuple is empty");

	return this;
}

static VALUE
pgvlr_materialize_field(t_pgvlt *this, int col)
{
	VALUE value = this->values[col];

	if( value == Qundef ){
		t_typemap *p_typemap = DATA_PTR( this->typemap );
		value = p_typemap->funcs.typecast_result_value(p_typemap, this->result, this->row_num, col);
		this->values[col] = value;
	}

	return value;
}

static void
pgvlr_materialize(t_pgvlt *this)
{
	int field_num;
	for(field_num = 0; field_num < this->num_fields; field_num++) {
		pgvlr_materialize_field(this, field_num);
	}

	this->result = Qnil;
	this->typemap = Qnil;
	this->row_num = -1;
}

/*
 * call-seq:
 *    res[ n ] -> value
 *
 * Returns field _n_.
 */
static VALUE
pgvlr_aref(VALUE self, VALUE index)
{
	VALUE value;
	t_pgvlt *this = pgvlt_get_this(self);
	int field_num = NUM2INT(index);

	if ( field_num < 0 || field_num >= this->num_fields )
		rb_raise( rb_eIndexError, "Index %d is out of range", field_num );

	value = pgvlr_materialize_field(this, field_num);

	return value;
}

static VALUE
pgvlr_num_fields_for_enum(VALUE self, VALUE args, VALUE eobj)
{
	t_pgvlt *this = pgvlt_get_this(self);
	return INT2NUM(this->num_fields);
}

/*
 * call-seq:
 *    res.each{ |value| ... }
 *
 * Invokes block for each field value in the tuple.
 */
static VALUE
pgvlr_each(VALUE self)
{
	t_pgvlt *this = pgvlt_get_this(self);
	int field_num;

	RETURN_SIZED_ENUMERATOR(self, 0, NULL, pgvlr_num_fields_for_enum);

	for(field_num = 0; field_num < this->num_fields; field_num++) {
		rb_yield(pgvlr_aref(self, INT2NUM(field_num)));
	}
	pgvlr_materialize(this);
	return self;
}

static VALUE
pgvlr_dump(VALUE self)
{
	VALUE a;
	t_pgvlt *this = pgvlt_get_this(self);

	pgvlr_materialize(this);
	a = rb_ary_new4(this->num_fields, &this->values[0]);
	return a;
}

static VALUE
pgvlr_load(VALUE self, VALUE a)
{
	int num_fields;
	int i;
	t_pgvlt *this;

	rb_check_frozen(self);
	rb_check_trusted(self);

	TypedData_Get_Struct(self, t_pgvlt, &pgvlt_type, this);
	if (this)
		rb_raise(rb_eTypeError, "tuple is not empty");

	if (!RB_TYPE_P(a, T_ARRAY))
		rb_raise(rb_eTypeError, "expected an array");
	num_fields = RARRAY_LEN(a);

	this = (t_pgvlt *)xmalloc(sizeof(*this) +  sizeof(*this->values) * num_fields);
	RTYPEDDATA_DATA(self) = this;

	this->result = Qnil;
	this->typemap = Qnil;
	this->row_num = -1;
	this->num_fields = num_fields;

	for( i = 0; i < num_fields; i++ ){
		VALUE v = RARRAY_AREF(a, i);
		if( v == Qundef )
			rb_raise(rb_eTypeError, "field %d is not materialized", i);
		this->values[i] = RARRAY_AREF(a, i);
	}

	return self;
}

void
init_pg_very_lazy_tuple()
{
	VALUE rb_cPG_LazyTuple;

	rb_cPG_LazyTuple = rb_define_class_under( rb_mPG, "LazyTuple", rb_cObject );
	rb_cPG_VeryLazyTuple = rb_define_class_under( rb_mPG, "VeryLazyTuple", rb_cPG_LazyTuple );
	rb_define_alloc_func( rb_cPG_VeryLazyTuple, pgvlt_s_allocate );
	rb_include_module(rb_cPG_VeryLazyTuple, rb_mEnumerable);

	rb_define_method(rb_cPG_VeryLazyTuple, "each", pgvlr_each, 0);
	rb_define_method(rb_cPG_VeryLazyTuple, "[]", pgvlr_aref, 1);

	/* methods for marshaling */
	rb_define_private_method(rb_cPG_VeryLazyTuple, "marshal_dump", pgvlr_dump, 0);
	rb_define_private_method(rb_cPG_VeryLazyTuple, "marshal_load", pgvlr_load, 1);
}
