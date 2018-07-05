#include "pg.h"

static VALUE rb_cPG_Tuple;

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

	/* Hash with maps field names to index into values[]
	 * Shared between all instances retrieved from one PG::Result.
	 */
	VALUE field_map;

	/* Row number within the result set. */
	int row_num;

	/* Materialized values. */
	VALUE values[0];
} t_pg_tuple;

static void
pg_tuple_gc_mark( t_pg_tuple *this )
{
	int i;

	if( !this ) return;
	rb_gc_mark( this->result );
	rb_gc_mark( this->typemap );
	rb_gc_mark( this->field_map );

	for( i = 0; i < (int)RHASH_SIZE(this->field_map); i++ ){
		rb_gc_mark( this->values[i] );
	}
}

static void
pg_tuple_gc_free( t_pg_tuple *this )
{
	if( !this ) return;
	xfree(this);
}

static size_t
pg_tuple_memsize( t_pg_tuple *this )
{
	return sizeof(*this) +  sizeof(*this->values) * RHASH_SIZE(this->field_map);
}

static const rb_data_type_t pg_tuple_type = {
	"pg",
	{
		(void (*)(void*))pg_tuple_gc_mark,
		(void (*)(void*))pg_tuple_gc_free,
		(size_t (*)(const void *))pg_tuple_memsize,
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
 *   PG::VeryTuple.allocate -> obj
 */
static VALUE
pg_tuple_s_allocate( VALUE klass )
{
	return TypedData_Wrap_Struct( klass, &pg_tuple_type, NULL );
}

VALUE
pg_tuple_new(VALUE result, int row_num, VALUE field_map)
{
	t_pg_tuple *this;
	VALUE self = pg_tuple_s_allocate( rb_cPG_Tuple );
	t_pg_result *p_result = pgresult_get_this(result);
	int num_fields = RHASH_SIZE(field_map);
	int i;

	this = (t_pg_tuple *)xmalloc(sizeof(*this) +  sizeof(*this->values) * num_fields);
	RTYPEDDATA_DATA(self) = this;

	this->result = result;
	this->typemap = p_result->typemap;
	this->field_map = field_map;
	this->row_num = row_num;

	for( i = 0; i < num_fields; i++ ){
		this->values[i] = Qundef;
	}

	return self;
}

static inline t_pg_tuple *
pg_tuple_get_this( VALUE self )
{
	t_pg_tuple *this;
	TypedData_Get_Struct(self, t_pg_tuple, &pg_tuple_type, this);
	if (this == NULL)
		rb_raise(rb_eTypeError, "tuple is empty");

	return this;
}

static VALUE
pg_tuple_materialize_field(t_pg_tuple *this, int col)
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
pg_tuple_detach(t_pg_tuple *this)
{
	this->result = Qnil;
	this->typemap = Qnil;
	this->row_num = -1;
}

static void
pg_tuple_materialize(t_pg_tuple *this)
{
	int field_num;
	for(field_num = 0; field_num < (int)RHASH_SIZE(this->field_map); field_num++) {
		pg_tuple_materialize_field(this, field_num);
	}

	pg_tuple_detach(this);
}

/*
 * call-seq:
 *    tup.fetch(key) → value
 *    tup.fetch(key, default) → value
 *    tup.fetch(key) { |key| block } → value
 *
 * Returns a field value by either column index or column name.
 *
 * An integer +key+ is interpreted as column index.
 * Negative values of index count from the end of the array.
 *
 * A string +key+ is interpreted as column name.
 *
 * If the key can't be found, there are several options:
 * With no other arguments, it will raise a IndexError exception;
 * if default is given, then that will be returned;
 * if the optional code block is specified, then that will be run and its result returned.
 */
static VALUE
pg_tuple_fetch(int argc, VALUE *argv, VALUE self)
{
	VALUE key;
	long block_given;
	VALUE index;
	int field_num;
	t_pg_tuple *this = pg_tuple_get_this(self);

	rb_check_arity(argc, 1, 2);
	key = argv[0];

	block_given = rb_block_given_p();
	if (block_given && argc == 2) {
		rb_warn("block supersedes default value argument");
	}

	switch(rb_type(key)){
		case T_FIXNUM:
		case T_BIGNUM:
			field_num = NUM2INT(key);
			if ( field_num < 0 )
				field_num = (int)RHASH_SIZE(this->field_map) + field_num;
			if ( field_num < 0 || field_num >= (int)RHASH_SIZE(this->field_map) ){
				if (block_given) return rb_yield(key);
				if (argc == 1) rb_raise( rb_eIndexError, "Index %d is out of range", field_num );
				return argv[1];
			}
			break;
		default:
			index = rb_hash_aref(this->field_map, key);

			if (index == Qnil) {
				if (block_given) return rb_yield(key);
				if (argc == 1) rb_raise( rb_eKeyError, "column not found" );
				return argv[1];
			}

			field_num = NUM2INT(index);
	}

	return pg_tuple_materialize_field(this, field_num);
}

/*
 * call-seq:
 *    res[ name ] -> value
 *
 * Returns field _name_.
 */
static VALUE
pg_tuple_aref(VALUE self, VALUE key)
{
	VALUE index;
	int field_num;
	t_pg_tuple *this = pg_tuple_get_this(self);

	switch(rb_type(key)){
		case T_FIXNUM:
		case T_BIGNUM:
			field_num = NUM2INT(key);
			if ( field_num < 0 )
				field_num = (int)RHASH_SIZE(this->field_map) + field_num;
			if ( field_num < 0 || field_num >= (int)RHASH_SIZE(this->field_map) )
				return Qnil;
			break;
		default:
			index = rb_hash_aref(this->field_map, key);
			if( index == Qnil ) return Qnil;
			field_num = NUM2INT(index);
	}

	return pg_tuple_materialize_field(this, field_num);
}

static VALUE
pg_tuple_num_fields_for_enum(VALUE self, VALUE args, VALUE eobj)
{
	t_pg_tuple *this = pg_tuple_get_this(self);
	return rb_hash_size(this->field_map);
}

static int
pg_tuple_yield_key_value(VALUE key, VALUE index, VALUE _this)
{
	t_pg_tuple *this = (t_pg_tuple *)_this;
	VALUE value = pg_tuple_materialize_field(this, NUM2INT(index));
	rb_yield_values(2, key, value);
	return ST_CONTINUE;
}

/*
 * call-seq:
 *    tup.each{ |value| ... }
 *
 * Invokes block for each field value in the tuple.
 */
static VALUE
pg_tuple_each(VALUE self)
{
	t_pg_tuple *this = pg_tuple_get_this(self);

	RETURN_SIZED_ENUMERATOR(self, 0, NULL, pg_tuple_num_fields_for_enum);

	rb_hash_foreach(this->field_map, pg_tuple_yield_key_value, (VALUE)this);

	pg_tuple_detach(this);
	return self;
}

/*
 * call-seq:
 *    tup.each_value{ |value| ... }
 *
 * Invokes block for each field value in the tuple.
 */
static VALUE
pg_tuple_each_value(VALUE self)
{
	t_pg_tuple *this = pg_tuple_get_this(self);
	int field_num;

	RETURN_SIZED_ENUMERATOR(self, 0, NULL, pg_tuple_num_fields_for_enum);

	for(field_num = 0; field_num < (int)RHASH_SIZE(this->field_map); field_num++) {
		rb_yield(pg_tuple_aref(self, INT2NUM(field_num)));
	}

	pg_tuple_detach(this);
	return self;
}


/*
 * call-seq:
 *    tup.values  -> Array
 *
 * Returns the values of this tuple as Array.
 * +res.tuple(i).values+ is equal to +res.tuple_values(i)+ .
 */
static VALUE
pg_tuple_values(VALUE self)
{
	t_pg_tuple *this = pg_tuple_get_this(self);

	pg_tuple_materialize(this);
	return rb_ary_new4(RHASH_SIZE(this->field_map), &this->values[0]);
}

static VALUE
pg_tuple_field_map(VALUE self)
{
	t_pg_tuple *this = pg_tuple_get_this(self);
	return this->field_map;
}

/*
 * call-seq:
 *    tup.length → integer
 *
 * Returns number of fields of this tuple.
 */
static VALUE
pg_tuple_length(VALUE self)
{
	t_pg_tuple *this = pg_tuple_get_this(self);
	return rb_hash_size(this->field_map);
}

/*
 * call-seq:
 *    tup.index(key) → integer
 *
 * Returns the field number which matches the given column name.
 */
static VALUE
pg_tuple_index(VALUE self, VALUE key)
{
	t_pg_tuple *this = pg_tuple_get_this(self);
	return rb_hash_aref(this->field_map, key);
}


static VALUE
pg_tuple_dump(VALUE self)
{
	VALUE values;
	VALUE a;
	t_pg_tuple *this = pg_tuple_get_this(self);

	pg_tuple_materialize(this);
	values = rb_ary_new4(RHASH_SIZE(this->field_map), &this->values[0]);
	a = rb_ary_new3(2, values, this->field_map);

	if (FL_TEST(self, FL_EXIVAR)) {
		rb_copy_generic_ivar(a, self);
		FL_SET(a, FL_EXIVAR);
	}
	return a;
}

static VALUE
pg_tuple_load(VALUE self, VALUE a)
{
	int num_fields;
	int i;
	t_pg_tuple *this;
	VALUE values;

	rb_check_frozen(self);
	rb_check_trusted(self);

	TypedData_Get_Struct(self, t_pg_tuple, &pg_tuple_type, this);
	if (this)
		rb_raise(rb_eTypeError, "tuple is not empty");

	if (!RB_TYPE_P(a, T_ARRAY) || RARRAY_LEN(a) != 2)
		rb_raise(rb_eTypeError, "expected an array of 2 elements");

	values = RARRAY_AREF(a, 0);
	num_fields = RARRAY_LEN(values);

	this = (t_pg_tuple *)xmalloc(sizeof(*this) +  sizeof(*this->values) * num_fields);
	RTYPEDDATA_DATA(self) = this;

	this->result = Qnil;
	this->typemap = Qnil;
	this->row_num = -1;
	this->field_map = RARRAY_AREF(a, 1);

	for( i = 0; i < num_fields; i++ ){
		VALUE v = RARRAY_AREF(values, i);
		if( v == Qundef )
			rb_raise(rb_eTypeError, "field %d is not materialized", i);
		this->values[i] = v;
	}

	if (FL_TEST(a, FL_EXIVAR)) {
		rb_copy_generic_ivar(self, a);
		FL_SET(self, FL_EXIVAR);
	}

	return self;
}

void
init_pg_tuple()
{
	rb_cPG_Tuple = rb_define_class_under( rb_mPG, "Tuple", rb_cObject );
	rb_define_alloc_func( rb_cPG_Tuple, pg_tuple_s_allocate );
	rb_include_module(rb_cPG_Tuple, rb_mEnumerable);

	rb_define_method(rb_cPG_Tuple, "fetch", pg_tuple_fetch, -1);
	rb_define_method(rb_cPG_Tuple, "[]", pg_tuple_aref, 1);
	rb_define_method(rb_cPG_Tuple, "each", pg_tuple_each, 0);
	rb_define_method(rb_cPG_Tuple, "each_value", pg_tuple_each_value, 0);
	rb_define_method(rb_cPG_Tuple, "values", pg_tuple_values, 0);
	rb_define_method(rb_cPG_Tuple, "length", pg_tuple_length, 0);
	rb_define_alias(rb_cPG_Tuple, "size", "length");
	rb_define_method(rb_cPG_Tuple, "index", pg_tuple_index, 1);

	rb_define_private_method(rb_cPG_Tuple, "field_map", pg_tuple_field_map, 0);

	/* methods for marshaling */
	rb_define_private_method(rb_cPG_Tuple, "marshal_dump", pg_tuple_dump, 0);
	rb_define_private_method(rb_cPG_Tuple, "marshal_load", pg_tuple_load, 1);
}
