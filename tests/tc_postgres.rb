require './pg.so'
require 'date'
require 'test/unit'
require 'pp'
require 'ipaddr'
class PGpoint
  attr_accessor :x, :y
  def initialize(x, y)
    @x = x
    @y = y
  end
  def self.parse(s)
    s =~ /\((.+),(.+)\)/
    x = Float($1)
    y = Float($2)
    PGpoint.new(x,y)
  end
  def to_s
    "(#{@x},#{@y})"
  end
  def == (other)
    other.is_a?(PGpoint) && (@x == other.x) && (@y == other.y)
  end
end

class PostgresTestCase < Test::Unit::TestCase

  def setup
    @conn = PGconn.new('dbname' => 'template1')
    @conn.exec("BEGIN")
  end

  def teardown
    @conn.exec("ROLLBACK")
    @conn.close
  end
  
  def test_bytea
    tuple = @conn.query("SELECT '12345\\\\111\\\\000\\\\112TEST'::bytea as bytea_value")[0]
    assert_equal("12345\111\000\112TEST", tuple['bytea_value'])
    assert_kind_of(PGbytea, tuple['bytea_value'])
    assert_equal("12345I\\\\000JTEST", PGconn.escape_bytea(tuple['bytea_value']))
    assert_equal("'12345I\\\\000JTEST'", PGconn.quote(tuple['bytea_value']))
    assert_equal("12345\111\000\112TEST", @conn.query("SELECT $1::bytea", tuple['bytea_value'])[0][0])
    assert_equal("12345\111\000\112TEST", @conn.query("SELECT #{PGconn.quote(tuple['bytea_value'])}::bytea")[0][0])
  end
  
  def test_parse_arrays
    @conn.exec("CREATE TABLE test_arrays (ar_i int[], ar_f float[], ar_t text[], ar_b boolean[], ar_n numeric[])")
    @conn.exec("INSERT INTO test_arrays VALUES ( ARRAY[1,2,3,4], ARRAY[1.5,2.5,3.5,4.4], ARRAY['one', 'two', 'three', 'suck''s'],
    ARRAY[false, true], ARRAY[1.01223456789012345, 3.141592558])")
    res = @conn.exec("SELECT * FROM test_arrays")
    tuple = res.result[0]
    tuple = res.result[0]
    assert_kind_of(Array, tuple['ar_i'])
    assert_kind_of(Array, tuple['ar_f'])
    assert_kind_of(Array, tuple['ar_t'])
    assert_kind_of(Array, tuple['ar_b'])
    assert_kind_of(Array, tuple['ar_n'])
    assert_kind_of(Fixnum, tuple['ar_i'][0])
    assert_kind_of(Float,  tuple['ar_f'][0])
    assert_kind_of(String, tuple['ar_t'][0])
    assert_equal(false, tuple['ar_b'][0])
    assert_equal(true,  tuple['ar_b'][1])
    assert_equal(4,     tuple['ar_i'][3])
    assert_equal(3.5,   tuple['ar_f'][2])
    assert_equal('one', tuple['ar_t'][0])
    assert_equal(BigDecimal("3.141592558"), tuple['ar_n'][1])
    float_arr = tuple['ar_f']
    float_arr[0] = -2
    float_arr[1] = -3
    clone_float = float_arr.clone
    @conn.exec("UPDATE test_arrays SET ar_f = $1", float_arr)
    ret_af = @conn.query("SELECT ar_f FROM test_arrays")[0][0]
    assert_equal(ret_af, clone_float)
    t_arr = tuple['ar_t']
    t_arr[1]="p'ass'ed"
    # check exec_params
    @conn.exec("UPDATE test_arrays SET ar_t = $1", t_arr)
    ret_at = @conn.query("SELECT ar_t FROM test_arrays")[0][0]
    assert_equal(ret_at, t_arr)
    # check quoting
    @conn.exec("UPDATE test_arrays SET ar_t = #{PGconn.quote(t_arr)}")
    ret_at = @conn.query("SELECT ar_t FROM test_arrays")[0][0]
    assert_equal(ret_at, t_arr)
    assert_equal("p'ass'ed", ret_at[1])
    assert_equal("'{\"one\",\"p''ass''ed\",\"three\",\"suck''s\"}'", PGconn.quote(ret_at))
    r1 = ["a\\", "", "b\"\ntes't\nlines"]
    assert_equal( r1 , @conn.query("SELECT $1::varchar[]", r1 ).first.first)
  end
  
  def test_simple_value_conversion
    query = <<-EOT
    select true as true_value,
       false as false_value,
       '2005-11-30'::date as date_value,
       '12:30:45'::time as time_value,
       '2005-12-06 12:30'::timestamp as date_time_value,
       1.5::float as float_value,
       12345.5678::numeric as numeric_value,
       1234.56::numeric(10) as numeric_10_value,
       12345.12345::numeric(10,5) as numeric_10_5_value
    EOT
    res = @conn.exec(query)
    assert_equal(res.num_tuples, 1)
    assert_equal(res.num_fields, 9)
    tuple = res.result[0]
    assert_equal(true, tuple['true_value'])
    assert_equal(false, tuple['false_value'])
    assert_equal(Date.parse('2005-11-30'), tuple['date_value'])
    assert_kind_of(Time, tuple['time_value'])
    assert_equal(Time.parse('12:30:45'), tuple['time_value'])
    assert_kind_of(DateTime, tuple['date_time_value'])
    assert_equal(DateTime.parse('2005-12-06 12:30'), tuple['date_time_value'])
    assert_equal(1.5, tuple['float_value'])
    assert_equal(BigDecimal("12345.5678"), tuple['numeric_value'])
    assert_equal(1235, tuple['numeric_10_value'])
    assert_kind_of(Integer, tuple['numeric_10_value'])
    assert_equal(BigDecimal("12345.12345"), tuple['numeric_10_5_value'])
  end
  
  def test_types_composition
    @conn.exec("CREATE TYPE inventory_item AS (name text,     supplier_id     integer,    price           numeric)")
    @conn.exec("CREATE TABLE on_hand ( item  inventory_item,  count     integer  )")
    @conn.load_composite_types
    @conn.exec("INSERT INTO on_hand VALUES (ROW('fuzzy dice', 42, 1.99), 1000)")
    r = @conn.exec("SELECT * FROM on_hand")
    tuple = r.result[0]
    d1 = tuple['item']
    assert_kind_of(PGrecord, d1)
    assert_equal(['name','supplier_id', 'price'], d1.names)  
    assert_equal(['fuzzy dice', 42, BigDecimal("1.99")], [d1['name'],d1['supplier_id'], d1['price']])
    d1['price']=BigDecimal("1.75")
    d1['name'] = "r'set"
    @conn.exec("UPDATE on_hand SET item = $1 ", d1)
    tuple = @conn.exec("SELECT * FROM on_hand").result[0]
    d2 = tuple['item']
    assert_equal(["r'set", 42, BigDecimal("1.75")], [d2['name'],d2['supplier_id'], d2['price']])
    assert_equal("'(\"r''set\",42,1.75)'", PGconn.quote(d2))
    @conn.exec("CREATE TYPE inventory_item2 AS (name text,    suppliers     integer[],    prices      float[])")
    @conn.exec("CREATE TABLE on_hand2 ( item  inventory_item2,  w_id integer  )")
    @conn.load_composite_types
    @conn.exec("INSERT INTO on_hand2 VALUES (ROW('fuzzy dice', ARRAY[42,43], ARRAY[1.99,1.75]), 10)")
    d3 = @conn.query("SELECT * FROM on_hand2")[0][0]
    assert_equal("'(\"fuzzy dice\",\"{42,43}\",\"{1.99,1.75}\")'", PGconn.quote(d3))
    assert_equal(['name', 'suppliers', 'prices'], d3.names)
    d3['suppliers'][2]=44
    d3['prices'][2]=1.85
    d3._name = "You ain't gonna \"need it\"!"
    @conn.exec("UPDATE on_hand2 SET item = $1", d3)
    d4 = @conn.query("SELECT * FROM on_hand2")[0][0]
    assert_equal("'(\"You ain''t gonna \\\\\"need it\\\\\"!\",\"{42,43,44}\",\"{1.99,1.75,1.85}\")'", PGconn.quote(d4))
    @conn.exec("DELETE FROM on_hand2")
    
    item = @conn.compose("inventory_item2", { :name => "fuzzy dice", :suppliers => [42, 43], :prices => [1.99, 1.75]} )
    assert_equal("'(\"fuzzy dice\",\"{42,43}\",\"{1.99,1.75}\")'", PGconn.quote(item))
    @conn.exec("INSERT INTO on_hand2 VALUES ($1, 10)", item)
    assert_equal(item, @conn.query("select item from on_hand2 where w_id = 10")[0][0])

    # compose should handle this too 
    item = @conn.compose("inventory_item2", item)
    assert_equal("'(\"fuzzy dice\",\"{42,43}\",\"{1.99,1.75}\")'", PGconn.quote(item))
    @conn.exec("INSERT INTO on_hand2 VALUES ($1, 10)", item)
    assert_equal(item, @conn.query("select item from on_hand2 where w_id = 10")[0][0])
  end

  def test_user_translate
    @conn.reg_translate("point", proc {|s| PGpoint.parse(s) })
    r = @conn.query("select '(1.4, 2.5)'::point")[0][0]
    assert_kind_of(PGpoint, r)
    assert_equal(1.4, r.x)
    assert_equal(2.5, r.y)
  end
  
  def test_user_value_format
    @conn.reg_translate("point", proc {|s| PGpoint.parse(s) })
    PGconn.reg_format(PGpoint,  proc {|p| p.to_s }, true)
    @conn.reg_array("point[]")
    
    p = PGpoint.new(1.4, 2.5)
    
    r = @conn.query("select #{PGconn.quote(p)}::point")[0][0]
    assert_kind_of(PGpoint, r)
    assert_equal(1.4, r.x)
    assert_equal(2.5, r.y)
    
    r = @conn.query("select $1::point", p)[0][0]
    assert_kind_of(PGpoint, r)
    assert_equal(1.4, r.x)
    assert_equal(2.5, r.y)

    @conn.prepare("t1", "select $1::point")
    r = @conn.exec_prepared("t1", p)[0][0]
    assert_kind_of(PGpoint, r)
    assert_equal(1.4, r.x)
    assert_equal(2.5, r.y)
    
    res = @conn.query("select $1::point[]", [[p,p],[p,p]])[0][0]
    assert_equal([[p,p],[p,p]], res)

    @conn.reg_translate("inet", proc  {|s| IPAddr.new(s) })
    PGconn.reg_format(IPAddr, proc {|a| a.to_s}, true)
    addr = IPAddr.new('192.168.1.0/24')
    assert_equal(addr, @conn.query("select $1::inet", addr)[0][0])
  end

  def test_user_custom_parse
    assert_equal(1234, @conn.parse("int", "1234"))
    assert_kind_of(Array, @conn.parse("int[]", "{1,2,3,4}"))
    assert_equal([1,2,3,4], @conn.parse("int[]", "{1,2,3,4}"))
    @conn.reg_translate("inet", proc  {|s| IPAddr.new(s) })
    addr = IPAddr.new('192.168.1.0')
    assert_equal(addr, @conn.parse("inet", '192.168.1.0'))
  end

  def test_select_one
    res = @conn.select_one("select 1 as a,2 as b union select 2 as a,3 as b order by 1")
    assert_equal([1,2], res)
  end
  def test_select_values
    res = @conn.select_values("select 1,2 union select 2,3 order by 1")
    assert_equal([1,2,2,3], res)
  end
  def test_select_value
    res = @conn.select_value("select 'test', 123")
    assert_equal("test", res)
  end
  def test_row_each 
    res = @conn.exec("select 1 as a union select 2 as a union select 3 as a order by 1")
    n = 1
    res.each do |tuple|
      assert_equal(n, tuple['a'])
      n +=1 
    end
  end

  def test_array_dimensions_no_translate
    PGconn.translate_results=false
    r = @conn.select_value("SELECT ARRAY[1,2] || ARRAY[[3,4]] AS array")
    assert_equal("[0:1][1:2]={{1,2},{3,4}}", r)
  end

  def test_array_dimensions_with_translate
    PGconn.translate_results=true
    r = @conn.select_value("SELECT ARRAY[1,2] || ARRAY[[3,4]] AS array")
    assert_equal([ [1,2], [3,4] ], r)
    assert_equal("[0:1][1:2]=", r.instance_variable_get("@dimensions"))
  end

  def test_quote_both_class_and_instance
    text = "'this is simple\n text"
    assert_equal @conn.quote(text), PGconn.quote(text)
    number = 3.1415926
    assert_equal @conn.quote(number), PGconn.quote(number)
  end
  
  def test_escape_bytea_both_class_and_instance
    text = "'this is simple\n binary\000\001\002"
    assert_equal @conn.escape_bytea(text), PGconn.escape_bytea(text)
  end

end
