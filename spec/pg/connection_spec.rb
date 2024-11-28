# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

require 'timeout'
require 'socket'
require 'pg'

# Work around ruby bug: https://bugs.ruby-lang.org/issues/19562
''.encode(Encoding::ISO8859_2)
''.encode(Encoding::KOI8_R)

describe PG::Connection do

	it "should give account about memory usage" do
		expect( ObjectSpace.memsize_of(@conn) ).to be > DATA_OBJ_MEMSIZE
	end

	it "should deny changes when frozen" do
		c = PG.connect(@conninfo).freeze
		expect{ c.setnonblocking true }.to raise_error(FrozenError)
		expect{ c.field_name_type = :symbol  }.to raise_error(FrozenError)
		expect{ c.set_default_encoding }.to raise_error(FrozenError)
		expect{ c.internal_encoding = nil }.to raise_error(FrozenError)
	ensure
		c&.finish
	end

	it "shouldn't be shareable for Ractor", :ractor do
		c = PG.connect(@conninfo)
		expect{ Ractor.make_shareable(c) }.to raise_error(Ractor::Error, /PG::Connection/)
	ensure
		c&.finish
	end

	it "should be usable with Ractor", :ractor do
		vals = Ractor.new(@conninfo) do |conninfo|
			conn = PG.connect(conninfo)
			conn.setnonblocking true
			conn.setnonblocking false
			conn.exec("SELECT 123").values
		ensure
			conn&.finish
		end.take

		expect( vals ).to eq( [["123"]] )
	end

	it "connects using 7 arguments in a Ractor", :ractor do
		vals = Ractor.new do
			PG.connect( 'localhost', @port, nil, nil, :test, nil, nil ) do |conn|
				conn.exec("SELECT 234").values
			end
		end.take

		expect( vals ).to eq( [["234"]] )
	end

	describe "#inspect", :without_transaction do
		it "should print host, port and user of a fresh connection, but not more" do
			expect( @conn.inspect ).to match(/<PG::Connection:[0-9a-fx]+ host=localhost port=#{@port} user=\w*>/)
		end

		it "should tell about finished connection" do
			conn = PG.connect(@conninfo)
			conn.finish
			expect( conn.inspect ).to match(/<PG::Connection:[0-9a-fx]+ finished>/)
		end

		it "should tell about connection status" do
			conn = PG::Connection.connect_start(@conninfo)
			expect( conn.inspect ).to match(/ status=CONNECTION_STARTED/)
		end

		it "should tell about pipeline mode", :postgresql_14 do
			@conn.enter_pipeline_mode
			expect( @conn.inspect ).to match(/ pipeline_status=PQ_PIPELINE_ON/)
		end

		it "should tell about transaction_status" do
			@conn.send_query "select 8"
			expect( @conn.inspect ).to match(/ transaction_status=PQTRANS_ACTIVE/)
		end

		it "should tell about nonblocking mode" do
			@conn.setnonblocking true
			expect( @conn.inspect ).to match(/ nonblocking=true/)
		end

		it "should tell about non UTF8 client encoding" do
			@conn.set_client_encoding "ISO-8859-1"
			expect( @conn.inspect ).to match(/ client_encoding=LATIN1/)
		end

		it "should tell about non default type_map_for_results" do
			@conn.type_map_for_results = PG::TypeMapByColumn.new([])
			expect( @conn.inspect ).to match(/ type_map_for_results=#<PG::TypeMapByColumn:[0-9a-fx]+>/)
		end

		it "should tell about non default type_map_for_queries" do
			@conn.type_map_for_queries = PG::TypeMapByColumn.new([])
			expect( @conn.inspect ).to match(/ type_map_for_queries=#<PG::TypeMapByColumn:[0-9a-fx]+>/)
		end

		it "should tell about encoder_for_put_copy_data" do
			@conn.encoder_for_put_copy_data = PG::TextEncoder::CopyRow.new
			expect( @conn.inspect ).to match(/ encoder_for_put_copy_data=#<PG::TextEncoder::CopyRow:[0-9a-fx]+>/)
		end

		it "should tell about decoder_for_get_copy_data" do
			@conn.decoder_for_get_copy_data = PG::TextDecoder::CopyRow.new
			expect( @conn.inspect ).to match(/ decoder_for_get_copy_data=#<PG::TextDecoder::CopyRow:[0-9a-fx]+>/)
		end
	end

	describe "PG::Connection#conninfo_parse" do
		it "encode and decode Hash to connection string to Hash" do
			hash = {
				:host => 'pgsql.example.com',
				:dbname => 'db01',
				'sslmode' => 'require',
				'service' => '',
				'password' => "\\ \t\n\"'",
			}
			optstring = described_class.connect_hash_to_string(hash)
			res = described_class.conninfo_parse(optstring).each_with_object({}){|h, o| o[h[:keyword].to_sym] = h[:val] if h[:val] }

			expect( res ).to eq( hash.transform_keys(&:to_sym) )
		end

		it "decode option string to Hash" do
			optstring = "host=overwritten host=c:\\\\pipe password = \\\\\\'\"  "
			res = described_class.conninfo_parse(optstring).each_with_object({}){|h, o| o[h[:keyword].to_sym] = h[:val] if h[:val] }

			expect( res ).to eq({
				host: 'c:\pipe',
				password: "\\'\"",
			})
		end

		it "can parse connection info strings kind of key=value" do
			ar = PG::Connection.conninfo_parse("user=auser  host=somehost  port=3334 dbname=db")
			expect( ar ).to be_kind_of( Array )
			expect( ar.first ).to be_kind_of( Hash )
			expect( ar.map{|a| a[:keyword] } ).to include( "dbname", "user", "password", "port" )
			expect( ar.map{|a| a[:val] } ).to include( "auser", "somehost", "3334", "db" )
		end

		it "can parse connection info strings kind of URI" do
			ar = PG::Connection.conninfo_parse("postgresql://auser@somehost:3334/db")
			expect( ar ).to be_kind_of( Array )
			expect( ar.first ).to be_kind_of( Hash )
			expect( ar.map{|a| a[:keyword] } ).to include( "dbname", "user", "password", "port" )
			expect( ar.map{|a| a[:val] } ).to include( "auser", "somehost", "3334", "db" )
		end

		it "can parse connection info strings with error" do
			expect{ PG::Connection.conninfo_parse("host='abc") }.to raise_error(PG::Error, /unterminated quoted string/)
			expect{ PG::Connection.conninfo_parse("host") }.to raise_error(PG::Error, /missing "=" after/)
		end
	end

	describe "PG::Connection#parse_connect_args" do
		it "shouldn't resolve absolute path in connection option string" do
			optstring = described_class.parse_connect_args(
				:host => '/var/socket'
			)
			expect( optstring ).to match( /(^|\s)host='\/var\/socket'/ )
			expect( optstring ).not_to match( /hostaddr/ )
		end

		it "shouldn't resolve Windows path in connection option string", :windows do
			optstring = described_class.parse_connect_args(
				:host => "C:\\pipe\\00"
			)
			expect( optstring ).to match( /(^|\s)host='C:\\\\pipe\\\\00'/ )
			expect( optstring ).not_to match( /hostaddr/ )
		end

		it "can create a connection option string from a Hash parameter" do
			optstring = described_class.parse_connect_args(
				:host => 'pgsql.example.com',
				:dbname => 'db01',
				'sslmode' => 'require',
				'hostaddr' => '1.2.3.4'
				)

			expect( optstring ).to be_a( String )
			expect( optstring ).to match( /(^|\s)host='pgsql.example.com'/ )
			expect( optstring ).to match( /(^|\s)dbname='db01'/ )
			expect( optstring ).to match( /(^|\s)sslmode='require'/ )
			expect( optstring ).to match( /(^|\s)hostaddr='1.2.3.4'/ )
		end

		it "can create a connection option string from positional parameters" do
			optstring = described_class.parse_connect_args( 'localhost', nil, '-c geqo=off', nil,
																						'sales' )

			expect( optstring ).to be_a( String )
			expect( optstring ).to match( /(^|\s)host='localhost'/ )
			expect( optstring ).to match( /(^|\s)dbname='sales'/ )
			expect( optstring ).to match( /(^|\s)options='-c geqo=off'/ )

			expect( optstring ).to_not match( /port=/ )
			expect( optstring ).to_not match( /tty=/ )
		end

		it "can create a connection option string from a mix of positional and hash parameters" do
			optstring = described_class.parse_connect_args( 'pgsql.example.com',
					:dbname => 'licensing', :user => 'jrandom',
					'hostaddr' => '1.2.3.4' )

			expect( optstring ).to be_a( String )
			expect( optstring ).to match( /(^|\s)host='pgsql.example.com'/ )
			expect( optstring ).to match( /(^|\s)dbname='licensing'/ )
			expect( optstring ).to match( /(^|\s)user='jrandom'/ )
			expect( optstring ).to match( /(^|\s)hostaddr='1.2.3.4'/ )
		end

		it "can create a connection option string from an option string and a hash" do
			optstring = described_class.parse_connect_args( 'dbname=original', :user => 'jrandom',
					'host' => 'www.ruby-lang.org,nonexisting-domaiiin.xyz,localhost' )

			expect( optstring ).to be_a( String )
			expect( optstring ).to match( /(^|\s)dbname='original'/ )
			expect( optstring ).to match( /(^|\s)user='jrandom'/ )
		end

		it "escapes single quotes and backslashes in connection parameters" do
			expect(
				described_class.parse_connect_args( password: "DB 'browser' \\" )
			).to match( /password='DB \\'browser\\' \\\\'/ )
		end

		let(:uri) { 'postgresql://user:pass@pgsql.example.com:222/db01?sslmode=require&hostaddr=4.3.2.1' }

		it "accepts an URI string" do
			string = described_class.parse_connect_args( uri )

			expect( string ).to be_a( String )
			expect( string ).to match( %r{^user='user' password='pass' dbname='db01' host='pgsql.example.com' hostaddr='4.3.2.1' port='222' sslmode='require' fallback_application_name} )
		end

		it "accepts an URI object" do
			require "uri"
			string = described_class.parse_connect_args( URI.parse(uri) )

			expect( string ).to be_a( String )
			expect( string ).to match( %r{^user='user' password='pass' dbname='db01' host='pgsql.example.com' hostaddr='4.3.2.1' port='222' sslmode='require' fallback_application_name} )
		end

		it "accepts an URI and adds parameters from hash" do
			string = described_class.parse_connect_args( uri + "&fallback_application_name=testapp", :connect_timeout => 2 )

			expect( string ).to be_a( String )
			expect( string ).to match( %r{^user='user' password='pass' dbname='db01' host='pgsql.example.com' hostaddr='4.3.2.1' port='222' fallback_application_name='testapp' sslmode='require' connect_timeout='2'} )
		end

		it "accepts an URI with a non-standard domain socket directory" do
			string = described_class.parse_connect_args( 'postgresql://%2Fvar%2Flib%2Fpostgresql/dbname' )

			expect( string ).to be_a( String )
			expect( string ).to match( %r{^dbname='dbname' host='/var/lib/postgresql'} )

			string = described_class.
				parse_connect_args( 'postgresql:///dbname', :host => '/var/lib/postgresql' )

			expect( string ).to be_a( String )
			expect( string ).to match( %r{^dbname='dbname' host='/var/lib/postgresql'} )
		end

		it "connects with defaults if no connection parameters are given" do
			expect( described_class.parse_connect_args ).to match( /fallback_application_name='[^']+'/ )
		end

		it "connects successfully with connection string" do
			conninfo_with_colon_in_password = "host=localhost user=a port=555 dbname=test password=a:a"

			string = described_class.parse_connect_args( conninfo_with_colon_in_password )

			expect( string ).to be_a( String )
			expect( string ).to match( %r{(^|\s)user='a'} )
			expect( string ).to match( %r{(^|\s)password='a:a'} )
			expect( string ).to match( %r{(^|\s)host='localhost'} )
			expect( string ).to match( %r{(^|\s)port='555'} )
			expect( string ).to match( %r{(^|\s)dbname='test'} )
		end

		it "sets the fallback_application_name on new connections" do
			conn_string = PG::Connection.parse_connect_args( 'dbname=test' )

			conn_name = conn_string[ /application_name='(.*?)'/, 1 ]
			expect( conn_name ).to include( $0[0..10] )
			expect( conn_name ).to include( $0[-10..-1] )
			expect( conn_name.length ).to be <= 64
		end

		it "sets a shortened fallback_application_name on new connections" do
			old_script_name = PG::Connection.class_eval("PROGRAM_NAME")
			begin
				prg = '/this/is/a/very/long/path/with/many/directories/to/our/beloved/ruby'
				PG::Connection.class_eval("PROGRAM_NAME=#{prg.inspect}")
				conn_string = PG::Connection.parse_connect_args( 'dbname=test' )
				conn_name = conn_string[ /application_name='(.*?)'/, 1 ]
				expect( conn_name ).to include( prg[0..10] )
				expect( conn_name ).to include( prg[-10..-1] )
				expect( conn_name.length ).to be <= 64
			ensure
				PG::Connection.class_eval("PROGRAM_NAME=PG.make_shareable(#{old_script_name.inspect})")
			end
		end
	end

	it "connects successfully with connection string" do
		tmpconn = described_class.connect( @conninfo )
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		tmpconn.finish
	end

	it "connects using 7 arguments converted to strings" do
		tmpconn = described_class.connect( 'localhost', @port, nil, nil, :test, nil, nil )
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		tmpconn.finish
	end

	it "connects using a hash of connection parameters" do
		tmpconn = described_class.connect(
			:host => 'localhost',
			:port => @port,
			:dbname => :test)
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		tmpconn.finish
	end

	it "connects using a hash of optional connection parameters" do
		tmpconn = described_class.connect(
			:host => 'localhost',
			:port => @port,
			:dbname => :test,
			:keepalives => 1)
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		tmpconn.finish
	end

	it "raises an exception when connecting with an invalid number of arguments" do
		expect {
			described_class.connect( 1, 2, 3, 4, 5, 6, 7, 'the-extra-arg' )
		}.to raise_error do |error|
			expect( error ).to be_an( ArgumentError )
			expect( error.message ).to match( /extra positional parameter/i )
			expect( error.message ).to match( /8/ )
			expect( error.message ).to match( /the-extra-arg/ )
		end
	end

	it "emits a suitable error_message at connection errors" do
		skip("Will be fixed in postgresql-15 on Windows") if RUBY_PLATFORM=~/mingw|mswin/

				expect {
					described_class.connect(
		                              :host => 'localhost',
		                              :port => @port,
		                              :dbname => "non-existent")
				}.to raise_error do |error|
			expect( error ).to be_an( PG::ConnectionBad )
			expect( error.message ).to match( /database "non-existent" does not exist/i )
			expect( error.message.encoding ).to eq( Encoding::BINARY )
		end
	end

	it "times out after connect_timeout seconds" do
		TCPServer.open( 'localhost', 54320 ) do |serv|
			start_time = Time.now
			expect {
				described_class.connect(
																host: 'localhost',
																port: 54320,
																connect_timeout: 1,
																dbname: "test")
			}.to raise_error do |error|
				expect( error ).to be_an( PG::ConnectionBad )
				expect( error.message ).to match( /timeout expired/ )
				if PG.library_version >= 120000
					expect( error.message ).to match( /\"localhost\"/ )
					expect( error.message ).to match( /port 54320/ )
				end
			end

			expect( Time.now - start_time ).to be_between(0.9, 10).inclusive
		end
	end

	context "with multiple PostgreSQL servers", :without_transaction do
		before :all do
			@port_ro = @port + 1
			@dbms = PG::TestingHelpers::PostgresServer.new("read-only",
				port: @port_ro,
				postgresql_conf: "default_transaction_read_only=on"
			)
		end

		after :all do
			@dbms&.teardown
		end

		it "honors target_session_attrs requirements" do
			uri = "postgres://localhost:#{@port_ro},localhost:#{@port}/postgres?target_session_attrs=read-write"
			PG.connect(uri) do |conn|
				expect( conn.port ).to eq( @port )
			end

			uri = "postgres://localhost:#{@port_ro},localhost:#{@port}/postgres?target_session_attrs=any"
			PG.connect(uri) do |conn|
				expect( conn.port ).to eq( @port_ro )
			end
		end
	end

	it "stops hosts iteration on authentication errors", :without_transaction, :ipv6 do
		@conn.exec("DROP USER IF EXISTS testusermd5")
		@conn.exec("CREATE USER testusermd5 PASSWORD 'secret'")

		uri = "host=::1,::1,127.0.0.1 port=#{@port_down},#{@port},#{@port} dbname=postgres user=testusermd5 password=wrong"
		error_match = if RUBY_PLATFORM=~/mingw|mswin/
			# It's a long standing issue of libpq, that the error text is not correctly returned when both client and server are running on Windows.
			# Instead a "Connection refused" is returned.
			/authenti.*testusermd5|Connection refused|server closed the connection unexpectedly/i
		else
			/authenti.*testusermd5/i
		end
		expect { PG.connect(uri) }.to raise_error(error_match)

		uri = "host=::1,::1,127.0.0.1 port=#{@port_down},#{@port},#{@port} dbname=postgres user=testusermd5 password=secret"
		PG.connect(uri) do |conn|
			expect( conn.host ).to eq( "::1" )
			expect( conn.port ).to eq( @port )
		end

		uri = "host=::1,::1,127.0.0.1 port=#{@port_down},#{@port_down},#{@port} dbname=postgres user=testusermd5 password=wrong"
		PG.connect(uri) do |conn|
			expect( conn.host ).to eq( "127.0.0.1" )
			expect( conn.port ).to eq( @port )
		end
	end

	it "connects using URI with multiple hosts", :postgresql_12 do
		uri = "postgres://localhost:#{@port_down},127.0.0.1:#{@port}/test?keepalives=1"
		tmpconn = described_class.connect( uri )
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		expect( tmpconn.port ).to eq( @port )
		expect( tmpconn.host ).to eq( "127.0.0.1" )
		expect( tmpconn.hostaddr ).to match( /\A(::1|127\.0\.0\.1)\z/ )
		tmpconn.finish
	end

	it "connects using URI with IPv6 hosts", :postgresql_12, :ipv6 do
		uri = "postgres://localhost:#{@port},[::1]:#{@port},/test"
		tmpconn = described_class.connect( uri )
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		expect( tmpconn.host ).to eq( "localhost" )
		expect( tmpconn.hostaddr ).to match( /\A(::1|127\.0\.0\.1)\z/ )
		tmpconn.finish
	end

	it "connects using URI with UnixSocket host", :postgresql_12, :unix_socket do
		uri = "postgres://#{@unix_socket.gsub("/", "%2F")}:#{@port}/test"
		tmpconn = described_class.connect( uri )
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		expect( tmpconn.host ).to eq( @unix_socket )
		expect( tmpconn.hostaddr ).to eq( "" )
		tmpconn.finish
	end

	it "connects with environment variables" do
		skip("Is broken before postgresql-12 on Windows") if RUBY_PLATFORM=~/mingw|mswin/ && PG.library_version < 120000

		tmpconn = with_env_vars(PGHOST: "localhost", PGPORT: @port, PGDATABASE: "test") do
			described_class.connect
		end
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		expect( tmpconn.host ).to eq( "localhost" )
		tmpconn.finish
	end

	it "connects using Hash with multiple hosts", :postgresql_12 do
		tmpconn = described_class.connect( host: "#{@unix_socket}xx,127.0.0.1,localhost", port: @port, dbname: "test" )
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		expect( tmpconn.host ).to eq( "127.0.0.1" )
		expect( tmpconn.hostaddr ).to match( /\A127\.0\.0\.1\z/ )
		tmpconn.finish
	end

	%i[open new connect sync_connect async_connect setdb setdblogin].each do |meth|
		it "can call ##{meth} of a derived class" do
			klass = Class.new(described_class) do
				alias execute exec
			end
			klass.send(meth, @conninfo) do |conn|
				expect( conn ).to be_a_kind_of( klass )
				expect( conn.execute("SELECT 1") ).to be_a_kind_of( PG::Result )
			end
		end
	end

	it "can connect asynchronously" do
		tmpconn = described_class.connect_start( @conninfo )
		expect( tmpconn ).to be_a( described_class )

		wait_for_polling_ok(tmpconn)
		expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		tmpconn.finish
	end

	it "can connect asynchronously for the duration of a block" do
		conn = nil

		described_class.connect_start(@conninfo) do |tmpconn|
			expect( tmpconn ).to be_a( described_class )
			conn = tmpconn

			wait_for_polling_ok(tmpconn)
			expect( tmpconn.status ).to eq( PG::CONNECTION_OK )
		end

		expect( conn ).to be_finished()
	end

	context "with async established connection" do
		before :each do
			@conn2 = described_class.connect_start( @conninfo )
			wait_for_polling_ok(@conn2)
			expect( @conn2 ).to still_be_usable
		end

		after :each do
			expect( @conn2 ).to still_be_usable
			@conn2.close
		end

		it "conn.send_query and IO.select work" do
			@conn2.send_query("SELECT 1")
			res = wait_for_query_result(@conn2)
			expect( res.values ).to eq([["1"]])
		end

		it "conn.send_query and conn.block work" do
			@conn2.send_query("SELECT 2")
			@conn2.block
			res = @conn2.get_last_result
			expect( res.values ).to eq([["2"]])
		end

		it "conn.async_query works" do
			res = @conn2.async_query("SELECT 3")
			expect( res.values ).to eq([["3"]])
			expect( @conn2 ).to still_be_usable

			res = @conn2.query("SELECT 4")
		end

		it "can work with changing IO while connection setup" do
			# The file_no of the socket IO can change while connecting.
			# This can happen when alternative hosts are tried,
			# while GSS authentication
			# and when falling back to unencrypted in sslmode:prefer

			# Consume some file descriptors and free them while the connection is established.
			pipes = 100.times.map{ IO.pipe }
			Thread.new do
				pipes.reverse_each do |ios|
					ios.each(&:close)
					sleep 0.01
				end
			end

			# Connect with SSL, but use a wrong client cert, so that connection is aborted.
			# A second connection is then started with a new IO.
			# And since the pipes above were freed in the concurrent thread above, there is a high chance that it's a lower file descriptor than before.
			conn = PG.connect( @conninfo + " sslcert=#{$pg_server.pgdata}/ruby-pg-ca-cert" )
			expect( conn.ssl_in_use? ).to be_falsey

			# The new connection should work even when the file descriptor has changed.
			res = conn.exec("SELECT 1")
			expect( res.values ).to eq([["1"]])

			conn.close
		end

		it "doesn't notify the wrong thread about closed socket (Bug #564)" do
			10.times do
				10.times.map do
					Thread.new do
						Thread.current.report_on_exception = false
						expect do
							threaded_conn = PG.connect( @conninfo + " sslcert=#{$pg_server.pgdata}/ruby-pg-ca-cert" )
							threaded_conn.exec("SELECT 1")
							threaded_conn.close
						end.not_to raise_error
					end
				end.each(&:join)
			end
		end

		it "can use conn.reset_start to restart the connection" do
			ios = IO.pipe
			conn = described_class.connect_start( @conninfo )
			wait_for_polling_ok(conn)

			# Close the two pipe file descriptors, so that the file descriptor of
			# newly established connection is probably distinct from the previous one.
			ios.each(&:close)
			conn.reset_start
			wait_for_polling_ok(conn, :reset_poll)

			# The new connection should work even when the file descriptor has changed.
			conn.send_query("SELECT 1")
			res = wait_for_query_result(conn)
			expect( res.values ).to eq([["1"]])

			conn.close
		end

		it "should properly close a socket IO when GC'ed" do
			# This results in
			#    Errno::ENOTSOCK: An operation was attempted on something that is not a socket.
			# on Windows when rb_w32_unwrap_io_handle() isn't called in pgconn_gc_free().
			5.times do
				conn = described_class.connect( @conninfo )
				conn.socket_io.close
			end
			GC.start
			IO.pipe.each(&:close)
		end

		it "provides the server generated error message" do
			skip("Will be fixed in postgresql-15 on Windows") if RUBY_PLATFORM=~/mingw|mswin/

			conn = described_class.connect_start(
				:host => 'localhost',
				:port => @port,
				:dbname => "non-existent")
			wait_for_polling_ok(conn)

			msg = conn.error_message
			expect( msg ).to match( /database "non-existent" does not exist/i )
			expect( msg.encoding ).to eq( Encoding::BINARY )
		end
	end

	context "in nonblocking mode" do
		after :each do
			@conn.setnonblocking(false)
		end

		it "defaults to blocking" do
			expect( @conn.isnonblocking ).to eq(false)
			expect( @conn.nonblocking? ).to eq(false)
		end

		it "can set nonblocking" do
			expect( @conn.setnonblocking(true) ).to be_nil
			expect( @conn.isnonblocking ).to eq(true)
			expect( @conn.nonblocking? ).to eq(true)

			expect( @conn.setnonblocking(false) ).to be_nil
			expect( @conn.isnonblocking ).to eq(false)
			expect( @conn.nonblocking? ).to eq(false)
		end

		it "sets nonblocking for the connection only" do
			co2 = PG.connect(@conninfo)
			expect( co2.setnonblocking(true) ).to be_nil
			expect( co2.isnonblocking ).to eq(true)
			expect( @conn.isnonblocking ).to eq(false)
			co2.finish
		end

		it "can send query" do
			@conn.setnonblocking(true)

			@conn.send_query("SELECT 3")
			wait_for_flush(@conn)

			res = wait_for_query_result(@conn)
			expect( res.values ).to eq([["3"]])
		end

		it "can send query with params" do
			@conn.setnonblocking(true)

			data = "x" * 1000 * 1000 * 10
			@conn.send_query_params("SELECT LENGTH($1)", [data])
			wait_for_flush(@conn)

			res = wait_for_query_result(@conn)
			expect( res.values ).to eq([[data.length.to_s]])
		end

		it "rejects to send lots of COPY data" do
			unless RUBY_PLATFORM =~ /i386-mingw|x86_64-darwin|x86_64-linux$/
				skip "this spec depends on out-of-memory condition in put_copy_data, which is not reliable on all platforms"
			end

			run_with_gate(200) do |conn, gate|
				conn.setnonblocking(true)

				res = nil
				conn.exec <<-EOSQL
					CREATE TEMP TABLE copytable (col1 TEXT);
				EOSQL

				conn.exec( "COPY copytable FROM STDOUT CSV" )
				gate.stop

				data = "x" * 1000 * 1000
				data << "\n"
				20000.times do |idx|
					res = conn.put_copy_data(data)
					break if res == false
				end
				expect( res ).to be_falsey

				gate.start
				conn.cancel
				conn.discard_results
			end
		end

		it "needs to flush data after send_query" do
			run_with_gate(200) do |conn, gate|
				conn.setnonblocking(true)

				gate.stop
				data = "x" * 1000 * 1000 * 30
				res = conn.send_query_params("SELECT LENGTH($1)", [data])
				expect( res ).to be_nil

				res = conn.flush
				expect( res ).to be_falsey

				gate.start
				until conn.flush
					IO.select(nil, [conn.socket_io], [conn.socket_io], 10)
				end
				expect( conn.flush ).to be_truthy

				res = conn.get_last_result
				expect( res.values ).to eq( [[data.length.to_s]] )
			end
		end

		it "returns immediately from get_copy_data(nonblock=true)" do
			expect do
				@conn.copy_data( "COPY (SELECT generate_series(0,999), NULL UNION ALL SELECT 1000, pg_sleep(10)) TO STDOUT" ) do |res|
					res = nil
					1000.times do
						res = @conn.get_copy_data(true)
						break if res==false
					end
					@conn.cancel
					expect( res ).to be_falsey
					while @conn.get_copy_data
					end
				end
			end.to raise_error(PG::QueryCanceled){|err| expect(err).to have_attributes(connection: @conn) }
		end
	end

	it "raises proper error when sending fails" do
		conn = described_class.connect_start( '127.0.0.1', 54320, "", "", "me", "xxxx", "somedb" )
		expect{ conn.exec 'SELECT 1' }.to raise_error(PG::UnableToSend, /no connection/){|err| expect(err).to have_attributes(connection: conn) }
	end

	it "doesn't leave stale server connections after finish" do
		res = @conn.exec(%[SELECT COUNT(*) AS n FROM pg_stat_activity
							WHERE usename IS NOT NULL AND application_name != ''])
		# there's still the global @conn, but should be no more
		old_count = res[0]['n']

		described_class.connect(@conninfo).finish

		sleep 0.5
		res = @conn.exec(%[SELECT COUNT(*) AS n FROM pg_stat_activity
							WHERE usename IS NOT NULL AND application_name != ''])
		# there's still the global @conn, but should be no more
		expect( res[0]['n'] ).to eq( old_count )
	end

	it "can retrieve it's connection parameters for the established connection" do
		expect( @conn.db ).to eq( "test" )
		expect( @conn.user ).to be_a_kind_of( String )
		expect( @conn.pass ).to eq( "" )
		expect( @conn.host ).to eq( "localhost" )
		expect( @conn.port ).to eq( @port )
		expect( @conn.tty ).to eq( "" )
		expect( @conn.options ).to eq( "" )
	end

	it "connects without port and then retrieves the default port" do
		gate = Helpers::TcpGateSwitcher.new(
				external_host: 'localhost',
				external_port: ENV['PGPORT'].to_i,
				internal_host: "127.0.0.1",
				internal_port: PG::DEF_PGPORT,
				debug: ENV['PG_DEBUG']=='1')

		PG.connect(host: "localhost",
				port: "",
				dbname: "test") do |conn|
			expect( conn.port ).to eq( PG::DEF_PGPORT )
		end

		PG.connect(hostaddr: "127.0.0.1",
				port: nil,
				dbname: "test") do |conn|
			expect( conn.port ).to eq( PG::DEF_PGPORT )
		end

		gate.finish
	rescue Errno::EADDRINUSE, Errno::EACCES => err
		skip err.to_s
	end

	it "can retrieve hostaddr for the established connection", :postgresql_12 do
		expect( @conn.hostaddr ).to match( /^127\.0\.0\.1$|^::1$/ )
	end

	it "can set error verbosity" do
		old = @conn.set_error_verbosity( PG::PQERRORS_TERSE )
		new = @conn.set_error_verbosity( old )
		expect( new ).to eq( PG::PQERRORS_TERSE )
	end

	it "can set error context visibility" do
		old = @conn.set_error_context_visibility( PG::PQSHOW_CONTEXT_NEVER )
		new = @conn.set_error_context_visibility( old )
		expect( new ).to eq( PG::PQSHOW_CONTEXT_NEVER )
	end

	let(:expected_trace_output_pre_14) do
		%{
		To backend> Msg Q
		To backend> "SELECT 1 AS one"
		To backend> Msg complete, length 21
		From backend> T
		From backend (#4)> 28
		From backend (#2)> 1
		From backend> "one"
		From backend (#4)> 0
		From backend (#2)> 0
		From backend (#4)> 23
		From backend (#2)> 4
		From backend (#4)> -1
		From backend (#2)> 0
		From backend> D
		From backend (#4)> 11
		From backend (#2)> 1
		From backend (#4)> 1
		From backend (1)> 1
		From backend> C
		From backend (#4)> 13
		From backend> "SELECT 1"
		From backend> Z
		From backend (#4)> 5
		From backend> Z
		From backend (#4)> 5
		From backend> T
		}.gsub( /^\t{2}/, '' ).lstrip
	end

	let(:expected_trace_output) do
		%{
		TIMESTAMP	F	20	Query	 "SELECT 1 AS one"
		TIMESTAMP	B	28	RowDescription	 1 "one" 0 0 23 4 -1 0
		TIMESTAMP	B	11	DataRow	 1 1 '1'
		TIMESTAMP	B	13	CommandComplete	 "SELECT 1"
		TIMESTAMP	B	5	ReadyForQuery	 T
		}.gsub( /^\t{2}/, '' ).lstrip
	end

	it "trace and untrace client-server communication", :unix do
		# be careful to explicitly close files so that the
		# directory can be removed and we don't have to wait for
		# the GC to run.
		trace_file = TEST_DIRECTORY + "test_trace.out"
		trace_io = trace_file.open( 'w', 0600 )
		@conn.trace( trace_io )
		trace_io.close

		@conn.exec("SELECT 1 AS one")
		@conn.untrace

		@conn.exec("SELECT 2 AS two")

		trace_data = trace_file.read

		if PG.library_version >= 140000
			trace_data.gsub!( /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d{6}/, 'TIMESTAMP' )

			expect( trace_data ).to eq( expected_trace_output )
		else
			# For async_exec the output will be different:
			#  From backend> Z
			#  From backend (#4)> 5
			# +From backend> Z
			# +From backend (#4)> 5
			#  From backend> T
			trace_data.sub!( /(From backend> Z\nFrom backend \(#4\)> 5\n){3}/m, '\\1\\1' )

			expect( trace_data ).to eq( expected_trace_output_pre_14 )
		end
	end

	it "allows a query to be cancelled" do
		start = Time.now
		@conn.set_notice_processor do |notice|
			@conn.cancel if notice =~ /foobar/
		end
		@conn.send_query "do $$ BEGIN RAISE NOTICE 'foobar'; PERFORM pg_sleep(10); END; $$ LANGUAGE plpgsql;"
		expect{ @conn.get_last_result }.to raise_error(PG::QueryCanceled){|err| expect(err).to have_attributes(connection: @conn) }
		expect( Time.now - start ).to be < 9.9
	end

	describe "#transaction" do

		it "automatically rolls back a transaction if an exception is raised" do
			# abort the per-example transaction so we can test our own
			@conn.exec( 'ROLLBACK' )
			@conn.exec( "CREATE TABLE pie ( flavor TEXT )" )

			begin
				expect {
					@conn.transaction do
						@conn.exec( "INSERT INTO pie VALUES ('rhubarb'), ('cherry'), ('schizophrenia')" )
						raise Exception, "Oh noes! All pie is gone!"
					end
				}.to raise_exception( Exception, /all pie is gone/i )

				res = @conn.exec( "SELECT * FROM pie" )
				expect( res.ntuples ).to eq( 0 )
			ensure
				@conn.exec( "DROP TABLE pie" )
			end
		end

		it "rolls back a transaction if a PG::RollbackTransaction exception is raised" do
			# abort the per-example transaction so we can test our own
			@conn.exec( 'ROLLBACK' )
			@conn.exec( "CREATE TABLE pie ( flavor TEXT )" )

			begin
				@conn.transaction do
					@conn.exec( "INSERT INTO pie VALUES ('rhubarb'), ('cherry'), ('schizophrenia')" )
					raise PG::RollbackTransaction
				end

				res = @conn.exec( "SELECT * FROM pie" )
				expect( res.ntuples ).to eq( 0 )
			ensure
				@conn.exec( "DROP TABLE pie" )
			end
		end

		it "commits even if the block includes an early break/return" do
			# abort the per-example transaction so we can test our own
			@conn.exec( 'ROLLBACK' )
			@conn.exec( "CREATE TABLE pie ( flavor TEXT )" )

			begin
				@conn.transaction do
					@conn.exec( "INSERT INTO pie VALUES ('rhubarb'), ('cherry'), ('schizophrenia')" )
					# a prior version would neither commit nor rollback when the block included an early break/return
					break
				end

				# if the previous transaction committed, the result should be visible from another conn/transaction
				@conn2 = PG.connect(@conninfo)
				begin
					res = @conn2.exec( "SELECT * FROM pie" )
					expect( res.ntuples ).to eq( 3 )
				ensure
					@conn2.close
				end
			ensure
				@conn.exec( "DROP TABLE pie" )
			end
		end

		it "passes the connection to the block and returns the block result" do
			# abort the per-example transaction so we can test our own
			@conn.exec( 'ROLLBACK' )

			res = @conn.transaction do |co|
				expect( co ).to equal( @conn )
				"transaction result"
			end
			expect( res ).to eq( "transaction result" )
		end
	end

	describe "large objects" do

		it "not read past the end of a large object" do
			@conn.transaction do
				oid = @conn.lo_create( 0 )
				fd = @conn.lo_open( oid, PG::INV_READ|PG::INV_WRITE )
				expect( @conn.lo_write( fd, "foobar" ) ).to eq( 6 )
				expect( @conn.lo_read( fd, 10 ) ).to be_nil()
				expect( @conn.lo_lseek( fd, 0, PG::SEEK_SET ) ).to eq( 0 )
				expect( @conn.lo_read( fd, 10 ) ).to eq( 'foobar' )
				expect( @conn.lo_close( fd ) ).to be_nil
				expect( @conn.lo_unlink( oid ) ).to be_nil
			end
		end

		it "large object can handle big data", :unix_socket do
			# Using lo_write with > 300000 bytes on a UnixSocket connection in nonblocking mode results in the following error:
			#   PG::UnableToSend: unexpected response from server; first received character was "V"
			# This is because the lo_write call doesn't wait for the response of the server function, but sends the next command early, so that results overlap.
			# Switching to blocking mode as part of lo_* calls fixes this issue and is tested here.

			uri = "postgres://#{@unix_socket.gsub("/", "%2F")}:#{@port}/test"
			conn = described_class.connect( uri )

			bytes = Random.urandom(512000)
			oid = conn.lo_creat
			conn.transaction do
				fd = conn.lo_open( oid, PG::INV_WRITE )
				conn.lo_write( fd, bytes )
				expect( conn.lo_close( fd ) ).to be_nil
			end

			conn.transaction do
				fd = conn.lo_open( oid, PG::INV_READ )
				bytes2 = conn.lo_read( fd, bytes.bytesize )
				expect( bytes2 ).to eq( bytes )
				expect( conn.lo_close( fd ) ).to be_nil
			end
			expect( conn.lo_unlink( oid ) ).to be_nil
		ensure
			conn&.finish
		end
	end

	it "supports explicitly calling #exec_params" do
		@conn.exec( "CREATE TABLE students ( name TEXT, age INTEGER )" )
		@conn.exec_params( "INSERT INTO students VALUES( $1, $2 )", ['Wally', 8] )
		@conn.exec_params( "INSERT INTO students VALUES( $1, $2 )", ['Sally', 6] )
		@conn.exec_params( "INSERT INTO students VALUES( $1, $2 )", ['Dorothy', 4] )

		res = @conn.exec_params( "SELECT name FROM students WHERE age >= $1", [6] )
		expect( res.values ).to eq( [ ['Wally'], ['Sally'] ] )
	end

	it "supports hash form parameters for #exec_params" do
		hash_param_bin = { value: ["00ff"].pack("H*"), type: 17, format: 1 }
		hash_param_nil = { value: nil, type: 17, format: 1 }
		res = @conn.exec_params( "SELECT $1, $2",
					[ hash_param_bin, hash_param_nil ] )
		expect( res.values ).to eq( [["\\x00ff", nil]] )
		expect( result_typenames(res) ).to eq( ['bytea', 'bytea'] )
	end

	it "should work with arbitrary number of params" do
		begin
			3.step( 12, 0.2 ) do |exp|
				num_params = (2 ** exp).to_i
				sql = num_params.times.map{|n| "$#{n+1}::INT" }.join(",")
				params = num_params.times.to_a
				res = @conn.exec_params( "SELECT #{sql}", params )
				expect( res.nfields ).to eq( num_params )
				expect( res.values ).to eq( [num_params.times.map(&:to_s)] )
			end
		rescue PG::ProgramLimitExceeded
			# Stop silently if the server complains about too many params
		end
	end

	it "can wait for NOTIFY events" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		t = Thread.new do
			begin
				conn = described_class.connect( @conninfo )
				sleep 0.1
				conn.exec( 'NOTIFY woo' )
			ensure
				conn.finish
			end
		end

		expect( @conn.wait_for_notify( 10 ) ).to eq( 'woo' )
		@conn.exec( 'UNLISTEN woo' )

		t.join
	end

	it "calls a block for NOTIFY events if one is given" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		t = Thread.new do
			begin
				conn = described_class.connect( @conninfo )
				sleep 0.1
				conn.exec( 'NOTIFY woo' )
			ensure
				conn.finish
			end
		end

		eventpid = event = nil
		@conn.wait_for_notify( 10 ) {|*args| event, eventpid = args }
		expect( event ).to eq( 'woo' )
		expect( eventpid ).to be_an( Integer )

		@conn.exec( 'UNLISTEN woo' )

		t.join
	end

	it "doesn't collapse sequential notifications" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )
		@conn.exec( 'LISTEN war' )
		@conn.exec( 'LISTEN woz' )

		begin
			conn = described_class.connect( @conninfo )
			conn.exec( 'NOTIFY woo' )
			conn.exec( 'NOTIFY war' )
			conn.exec( 'NOTIFY woz' )
		ensure
			conn.finish
		end

		channels = []
		3.times do
			channels << @conn.wait_for_notify( 2 )
		end

		expect( channels.size ).to eq( 3 )
		expect( channels ).to include( 'woo', 'war', 'woz' )

		@conn.exec( 'UNLISTEN woz' )
		@conn.exec( 'UNLISTEN war' )
		@conn.exec( 'UNLISTEN woo' )
	end

	it "returns notifications which are already in the queue before wait_for_notify is called " +
	   "without waiting for the socket to become readable" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		begin
			conn = described_class.connect( @conninfo )
			conn.exec( 'NOTIFY woo' )
		ensure
			conn.finish
		end

		# Cause the notification to buffer, but not be read yet
		@conn.exec( 'SELECT 1' )

		expect( @conn.wait_for_notify( 10 ) ).to eq( 'woo' )
		@conn.exec( 'UNLISTEN woo' )
	end

	it "can receive notices while waiting for NOTIFY without exceeding the timeout" do
		retries = 20
		loop do
			@conn.get_last_result  # clear pending results
			expect( retries-=1 ).to be > 0

			notices = []
			lt = nil
			@conn.set_notice_processor do |msg|
				notices << [msg, Time.now - lt] if lt
				lt = Time.now
			end

			st = Time.now
			# Send two notifications while a query is running
			@conn.send_query <<-EOT
				DO $$ BEGIN
					RAISE NOTICE 'notice1';
					PERFORM pg_sleep(0.3);
					RAISE NOTICE 'notice2';
				END; $$ LANGUAGE plpgsql
			EOT

			# wait_for_notify recalculates the internal select() timeout after each all to set_notice_processor
			expect( @conn.wait_for_notify( 0.5 ) ).to be_nil
			et = Time.now

			# The notifications should have been delivered while (not after) the query is running.
			# Check this and retry otherwise.
			next unless notices.size == 1         # should have received one notice
			expect( notices.first[0] ).to match(/notice2/)
			next unless notices.first[1] >= 0.29  # should take at least the pg_sleep() duration
			next unless notices.first[1] < 0.49   # but should be shorter than the wait_for_notify() duration
			next unless et - st < 0.75            # total time should not exceed wait_for_notify() + pg_sleep() duration
			expect( et - st ).to be >= 0.49       # total time must be at least the wait_for_notify() duration
			break
		end
	end

	it "yields the result if block is given to exec" do
		rval = @conn.exec( "select 1234::int as a union select 5678::int as a" ) do |result|
			values = []
			expect( result ).to be_kind_of( PG::Result )
			expect( result.ntuples ).to eq( 2 )
			result.each do |tuple|
				values << tuple['a']
			end
			values
		end

		expect( rval.size ).to eq( 2 )
		expect( rval ).to include( '5678', '1234' )
	end

	it "correctly finishes COPY queries passed to #exec" do
		@conn.exec( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT" )

		results = []
		begin
			data = @conn.get_copy_data( true )
			if false == data
				@conn.block( 2.0 )
				data = @conn.get_copy_data( true )
			end
			results << data if data
		end until data.nil?

		expect( results.size ).to eq( 2 )
		expect( results ).to include( "1\n", "2\n" )
	end

	it "#get_result should send remaining data before waiting" do
		str = "abcd" * 2000 + "\n"
		@conn.exec( "CREATE TEMP TABLE copytable2 (col1 TEXT)" )
		@conn.exec( "COPY copytable2 FROM STDOUT" )

		1000.times do
			@conn.sync_put_copy_data(str)
		end
		@conn.sync_put_copy_end
		res = @conn.get_last_result
		expect( res.result_status ).to eq( PG::PGRES_COMMAND_OK )
		@conn.exec( "DROP TABLE IF EXISTS copytable2" )
	end

	describe "#copy_data" do
		it "can process #copy_data output queries in text format" do
			rows = []
			res2 = @conn.copy_data( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT" ) do |res|
				expect( res.result_status ).to eq( PG::PGRES_COPY_OUT )
				expect( res.nfields ).to eq( 1 )
				expect( res.binary_tuples ).to eq( 0 )
				while row=@conn.get_copy_data
					rows << row
				end
			end
			expect( rows ).to eq( ["1\n", "2\n"] )
			expect( res2.result_status ).to eq( PG::PGRES_COMMAND_OK )
			expect( @conn ).to still_be_usable
		end

		it "can process #copy_data output queries in binary format" do
			rows = []
			res2 = @conn.copy_data( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT (FORMAT binary)" ) do |res|
				expect( res.result_status ).to eq( PG::PGRES_COPY_OUT )
				expect( res.nfields ).to eq( 1 )
				expect( res.binary_tuples ).to eq( 1 )
				while row=@conn.get_copy_data
					rows << row
				end
			end
			expect( rows ).to eq( ["PGCOPY\n\xFF\r\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x04\x00\x00\x00\x01".b, "\x00\x01\x00\x00\x00\x04\x00\x00\x00\x02".b, "\xFF\xFF".b] )
			expect( res2.result_status ).to eq( PG::PGRES_COMMAND_OK )
			expect( @conn ).to still_be_usable
		end

		it "can handle incomplete #copy_data output queries" do
			expect {
				@conn.copy_data( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT" ) do |res|
					@conn.get_copy_data
				end
			}.to raise_error(PG::NotAllCopyDataRetrieved, /Not all/){|err| expect(err).to have_attributes(connection: @conn) }
			expect( @conn ).to still_be_usable
		end

		it "can handle client errors in #copy_data for output" do
			expect {
				@conn.copy_data( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT" ) do
					raise "boom"
				end
			}.to raise_error(RuntimeError, "boom")
			expect( @conn ).to still_be_usable
		end

		it "can handle client errors after all data is consumed in #copy_data for output" do
			expect {
				@conn.copy_data( "COPY (SELECT 1) TO STDOUT" ) do |res|
					while @conn.get_copy_data
					end
					raise "boom"
				end
			}.to raise_error(RuntimeError, "boom")
			expect( @conn ).to still_be_usable
		end

		it "can handle server errors in #copy_data for output" do
			@conn.exec "ROLLBACK"
			@conn.transaction do
				@conn.exec( "CREATE FUNCTION errfunc() RETURNS int AS $$ BEGIN RAISE 'test-error'; END; $$ LANGUAGE plpgsql;" )
				expect {
					@conn.copy_data( "COPY (SELECT errfunc()) TO STDOUT" ) do |res|
						while @conn.get_copy_data
						end
					end
				}.to raise_error(PG::Error, /test-error/){|err| expect(err).to have_attributes(connection: @conn) }
			end
			expect( @conn ).to still_be_usable
		end

		it "can process #copy_data input queries in text format" do
			@conn.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
			res2 = @conn.copy_data( "COPY copytable FROM STDOUT" ) do |res|
				expect( res.result_status ).to eq( PG::PGRES_COPY_IN )
				expect( res.nfields ).to eq( 1 )
				expect( res.binary_tuples ).to eq( 0 )
				@conn.put_copy_data "1\n"
				@conn.put_copy_data "2\n"
			end
			expect( res2.result_status ).to eq( PG::PGRES_COMMAND_OK )

			expect( @conn ).to still_be_usable

			res = @conn.exec( "SELECT * FROM copytable ORDER BY col1" )
			expect( res.values ).to eq( [["1"], ["2"]] )
			@conn.exec( "DROP TABLE IF EXISTS copytable" )
		end

		it "can process #copy_data input queries in binary format" do
			@conn.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
			res2 = @conn.copy_data( "COPY copytable FROM STDOUT (FORMAT binary)" ) do |res|
				expect( res.result_status ).to eq( PG::PGRES_COPY_IN )
				expect( res.nfields ).to eq( 1 )
				expect( res.binary_tuples ).to eq( 1 )
				# header and first record ("1")
				@conn.put_copy_data "PGCOPY\n\xFF\r\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x31".b
				# second record ("2")
				@conn.put_copy_data "\x00\x01\x00\x00\x00\x01\x32".b
				# trailer
				@conn.put_copy_data "\xFF\xFF".b
			end
			expect( res2.result_status ).to eq( PG::PGRES_COMMAND_OK )

			expect( @conn ).to still_be_usable

			res = @conn.exec( "SELECT * FROM copytable ORDER BY col1" )
			expect( res.values ).to eq( [["1"], ["2"]] )
			@conn.exec( "DROP TABLE IF EXISTS copytable" )
		end

		it "can process #copy_data input queries with lots of data" do
			str = "abcd" * 2000 + "\n"
			@conn.exec( "CREATE TEMP TABLE copytable2 (col1 TEXT)" )
			@conn.copy_data( "COPY copytable2 FROM STDOUT" ) do |res|
				1000.times do
					@conn.put_copy_data(str)
				end
			end
			expect( @conn ).to still_be_usable

			res = @conn.exec( "SELECT COUNT(*) FROM copytable2" )
			expect( res.values ).to eq( [["1000"]] )
			res = @conn.exec( "SELECT * FROM copytable2 LIMIT 1" )
			expect( res.values ).to eq( [[str.chomp]] )
			@conn.exec( "DROP TABLE IF EXISTS copytable2" )
		end

		it "can handle client errors in #copy_data for input" do
			@conn.exec "ROLLBACK"
			@conn.transaction do
				@conn.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
				expect {
					@conn.copy_data( "COPY copytable FROM STDOUT" ) do |res|
						raise "boom"
					end
				}.to raise_error(RuntimeError, "boom")
			end

			expect( @conn ).to still_be_usable
			@conn.exec( "DROP TABLE IF EXISTS copytable" )
		end

		it "can handle server errors in #copy_data for input" do
			@conn.exec "ROLLBACK"
			@conn.transaction do
				@conn.exec( "CREATE TEMP TABLE copytable (col1 INT)" )
				expect {
					@conn.copy_data( "COPY copytable FROM STDOUT" ) do |res|
						@conn.put_copy_data "xyz\n"
					end
				}.to raise_error(PG::Error, /invalid input syntax for .*integer/){|err| expect(err).to have_attributes(connection: @conn) }
			end
			expect( @conn ).to still_be_usable
			@conn.exec( "DROP TABLE IF EXISTS copytable" )
		end

		it "doesn't lose client error when #copy_data can not be finished" do
			@conn.exec "ROLLBACK"
			@conn.transaction do
				@conn.exec( "CREATE TEMP TABLE copytable (col1 INT)" )
				expect {
					@conn.copy_data( "COPY copytable FROM STDOUT" ) do |res|
						@conn.discard_results # end copy state so that put_copy_end fails in copy_data
						raise "boom"
					end
				}.to raise_error(RuntimeError, "boom")
			end
			expect( @conn ).to still_be_usable
			@conn.exec( "DROP TABLE IF EXISTS copytable" )
		end

		it "gracefully handle SQL statements while in #copy_data for input" do
			@conn.exec "ROLLBACK"
			@conn.exec( "CREATE TEMP TABLE copytable (col1 INT)" )
			expect {
				@conn.copy_data( "COPY copytable FROM STDOUT" ) do |res|
					@conn.exec "SELECT 1"
				end
			}.to raise_error(PG::LostCopyState, /another SQL query/){|err| expect(err).to have_attributes(connection: @conn) }
			expect( @conn ).to still_be_usable
			@conn.exec( "DROP TABLE copytable" )
		end

		it "gracefully handle SQL statements while in #copy_data for output" do
			@conn.exec "ROLLBACK"
			expect {
				@conn.copy_data( "COPY (VALUES(1), (2)) TO STDOUT" ) do |res|
					@conn.exec "SELECT 3"
				end
			}.to raise_error(PG::LostCopyState, /another SQL query/){|err| expect(err).to have_attributes(connection: @conn) }
			expect( @conn ).to still_be_usable
		end

		it "should raise an error for non copy statements in #copy_data" do
			expect {
				@conn.copy_data( "SELECT 1" ){}
			}.to raise_error(ArgumentError, /no COPY/)

			expect( @conn ).to still_be_usable
		end

		it "#copy_data raises error in nonblocking mode" do
			@conn.setnonblocking(true)
			expect {
				@conn.copy_data( "COPY copytable FROM STDOUT" )
			}.to raise_error(PG::NotInBlockingMode){|err| expect(err).to have_attributes(connection: @conn) }
			@conn.setnonblocking(false)
		end
	end

	it "described_class#block shouldn't block a second thread" do
		start = Time.now
		t = Thread.new do
			@conn.send_query( "select pg_sleep(3)" )
			@conn.block
		end

		sleep 0.5
		expect( t ).to be_alive()
		@conn.cancel
		expect( t.value ).to be_truthy
		expect( (Time.now - start) ).to be < 3
	end

	it "described_class#block should allow a timeout" do
		@conn.send_query( "select pg_sleep(100)" )

		start = Time.now
		res = @conn.block( 0.3 )
		finish = Time.now
		@conn.cancel

		expect( res ).to be_falsey
		expect( (finish - start) ).to be_between( 0.2, 99 ).exclusive
	end

	it "can return the default connection options" do
		expect( described_class.conndefaults ).to be_a( Array )
		expect( described_class.conndefaults ).to all( be_a(Hash) )
		expect( described_class.conndefaults[0] ).to include( :keyword, :label, :dispchar, :dispsize )
		expect( @conn.conndefaults ).to eq( described_class.conndefaults )
	end

	it "can return the default connection options as a Hash" do
		expect( described_class.conndefaults_hash ).to be_a( Hash )
		expect( described_class.conndefaults_hash ).to include( :user, :password, :dbname, :host, :port )
		expect( ['5432', '54321', @port.to_s] ).to include( described_class.conndefaults_hash[:port] )
		expect( @conn.conndefaults_hash ).to eq( described_class.conndefaults_hash )
	end

	it "can return the connection's connection options" do
		expect( @conn.conninfo ).to be_a( Array )
		expect( @conn.conninfo ).to all( be_a(Hash) )
		expect( @conn.conninfo[0] ).to include( :keyword, :label, :dispchar, :dispsize )
	end


	it "can return the connection's connection options as a Hash" do
		expect( @conn.conninfo_hash ).to be_a( Hash )
		expect( @conn.conninfo_hash ).to include( :user, :password, :connect_timeout, :dbname, :host )
		expect( @conn.conninfo_hash[:dbname] ).to eq( 'test' )
	end

	describe "connection information related to SSL" do

		it "can retrieve connection's ssl state" do
			expect( @conn.ssl_in_use? ).to be true
		end

		it "can retrieve connection's ssl attribute_names" do
			expect( @conn.ssl_attribute_names ).to be_a(Array)
		end

		it "can retrieve a single ssl connection attribute" do
			expect( @conn.ssl_attribute('dbname') ).to eq( nil )
			expect( @conn.ssl_attribute('protocol') ).to match( /^TLSv/ )
			expect( @conn.ssl_attribute('key_bits') ).to match( /^\d+$/ )
		end

		it "can retrieve all connection's ssl attributes" do
			expect( @conn.ssl_attributes ).to be_a_kind_of( Hash )
		end
	end


	it "honors the connect_timeout connection parameter" do
		conn = PG.connect( port: @port, dbname: 'test', connect_timeout: 11 )
		begin
			expect( conn.conninfo_hash[:connect_timeout] ).to eq( "11" )
		ensure
			conn.finish
		end
	end

	it "can connect concurrently in parallel threads" do
		res = 5.times.map do |idx|
			Thread.new do
				PG.connect(@conninfo) do |conn|
					[conn.ssl_in_use?, conn.exec("select 82").getvalue(0, 0)]
				end
			end
		end.map(&:value)
		expect( res ).to eq( [[true, "82"]] * 5 )
	end

	describe "deprecated password encryption method" do
		it "can encrypt password for a given user" do
			expect( described_class.encrypt_password("postgres", "postgres") ).to match( /\S+/ )
		end

		it "raises an appropriate error if either of the required arguments is not valid" do
			expect {
				described_class.encrypt_password( nil, nil )
			}.to raise_error( TypeError )
			expect {
				described_class.encrypt_password( "postgres", nil )
			}.to raise_error( TypeError )
			expect {
				described_class.encrypt_password( nil, "postgres" )
			}.to raise_error( TypeError )
		end
	end

	describe "password encryption method" do
		it "can encrypt without algorithm" do
			expect( @conn.encrypt_password("postgres", "postgres") ).to match( /\S+/ )
			expect( @conn.encrypt_password("postgres", "postgres", nil) ).to match( /\S+/ )
		end

		it "can encrypt with algorithm" do
			expect( @conn.encrypt_password("postgres", "postgres", "md5") ).to match( /md5\S+/i )
			expect( @conn.encrypt_password("postgres", "postgres", "scram-sha-256") ).to match( /SCRAM-SHA-256\S+/i )
		end

		it "raises an appropriate error if either of the required arguments is not valid" do
			expect {
				@conn.encrypt_password( nil, nil )
			}.to raise_error( TypeError )
			expect {
				@conn.encrypt_password( "postgres", nil )
			}.to raise_error( TypeError )
			expect {
				@conn.encrypt_password( nil, "postgres" )
			}.to raise_error( TypeError )
			expect {
				@conn.encrypt_password( "postgres", "postgres", :invalid )
			}.to raise_error( TypeError )
			expect {
				@conn.encrypt_password( "postgres", "postgres", "invalid" )
			}.to raise_error( PG::Error, /unrecognized/ )
		end
	end


	it "allows fetching a column of values from a result by column number" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect( res.column_values( 0 ) ).to eq( %w[1 2 3] )
		expect( res.column_values( 1 ) ).to eq( %w[2 3 4] )
	end


	it "allows fetching a column of values from a result by field name" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect( res.field_values( 'column1' ) ).to eq( %w[1 2 3] )
		expect( res.field_values( 'column2' ) ).to eq( %w[2 3 4] )
	end


	it "raises an error if selecting an invalid column index" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect {
			res.column_values( 20 )
		}.to raise_error( IndexError )
	end


	it "raises an error if selecting an invalid field name" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect {
			res.field_values( 'hUUuurrg' )
		}.to raise_error( IndexError )
	end


	it "raises an error if column index is not a number" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect {
			res.column_values( 'hUUuurrg' )
		}.to raise_error( TypeError )
	end


	it "handles server close while asynchronous connect" do
		serv = TCPServer.new( '127.0.0.1', 54320 )
		conn = described_class.connect_start( '127.0.0.1', 54320, "", "", "me", "xxxx", "somedb" )
		expect( [PG::PGRES_POLLING_WRITING, PG::CONNECTION_OK] ).to include conn.connect_poll
		select( nil, [conn.socket_io], nil, 0.2 )
		serv.close
		if conn.connect_poll == PG::PGRES_POLLING_READING
			select( [conn.socket_io], nil, nil, 0.2 )
		end
		expect( conn.connect_poll ).to eq( PG::PGRES_POLLING_FAILED )
	end

	describe "#discard_results" do

		it "discards previous results" do
			@conn.send_query( "select 1" )
			expect( @conn.discard_results ).to eq( true )
			@conn.send_query( "select 41 as one" )
			res = @conn.get_last_result
			expect( res.to_a ).to eq( [{ 'one' => '41' }] )
		end

		it "returns nil when in idle state", :without_transaction do
			expect( @conn.discard_results ).to eq( nil )

			@conn.transaction do
				expect( @conn.discard_results ).to eq( nil )
			end

			@conn.transaction do
				@conn.send_query( "WRONG COMMAND" )
				@conn.get_result
				@conn.get_result

				expect( @conn.discard_results ).to be_nil
			end
		end

		it "returns false on connection failures" do
			conn = PG.connect(@conninfo)
			conn.send_query("select pg_terminate_backend(pg_backend_pid());")
			expect( conn.discard_results ).to eq( false )
		end
	end

	it "discards previous results (if any) before waiting on #exec" do
		@conn.send_query( "select 1" )
		res = @conn.exec( "select 42 as one" )
		expect( res.to_a ).to eq( [{ 'one' => '42' }] )
	end

	it "discards previous errors before waiting on #exec", :without_transaction do
		@conn.send_query( "ERROR" )
		res = @conn.exec( "select 43 as one" )
		expect( res.to_a ).to eq( [{ 'one' => '43' }] )
	end

	it "calls the block if one is provided to #exec" do
		result = nil
		@conn.exec( "select 47 as one" ) do |pg_res|
			result = pg_res[0]
		end
		expect( result ).to eq( { 'one' => '47' } )
	end

	it "carries the connection in case of connection errors" do
		conn = PG.connect(@conninfo)
		expect {
			conn.exec("select pg_terminate_backend(pg_backend_pid());")
		}.to raise_error(PG::Error, /connection has been closed|terminating connection|server closed the connection unexpectedly/i){|err| expect(err).to have_attributes(connection: conn) }
	end

	it "raises a rescue-able error if #finish is called twice", :without_transaction do
		conn = PG.connect( @conninfo )

		conn.finish
		expect { conn.finish }.to raise_error( PG::ConnectionBad, /connection is closed/i ){|err| expect(err).to have_attributes(connection: conn) }
	end

	it "can use conn.reset to restart the connection" do
		ios = IO.pipe
		conn = PG.connect( @conninfo )

		# Close the two pipe file descriptors, so that the file descriptor of
		# newly established connection is probably distinct from the previous one.
		ios.each(&:close)
		res = conn.reset
		expect( res ).to eq( conn )

		# The new connection should work even when the file descriptor has changed.
		expect( conn.exec("SELECT 1").values ).to eq([["1"]])
		conn.close
	end

	it "refreshes DNS address while conn.reset", :without_transaction, :ipv6 do
		set_etc_hosts "::1", "rubypg_test1"
		conn = described_class.connect( "postgres://rubypg_test1/test" )
		conn.exec("select 1")

		set_etc_hosts "127.0.0.1", "rubypg_test1"
		conn.reset
		conn.exec("select 1")

		set_etc_hosts "::2", "rubypg_test1"
		expect do
			conn.reset
			conn.exec("select 1")
		end.to raise_error(PG::Error)
	end


	it "closes the IO fetched from #socket_io when the connection is closed", :without_transaction do
		conn = PG.connect( @conninfo )
		io = conn.socket_io
		conn.finish
		expect( io ).to be_closed()
		expect { conn.socket_io }.to raise_error( PG::ConnectionBad, /connection is closed/i ){|err| expect(err).to have_attributes(connection: conn) }
	end

	it "closes the IO fetched from #socket_io when the connection is reset", :without_transaction do
		conn = PG.connect( @conninfo )
		io = conn.socket_io
		conn.reset
		expect( io ).to be_closed()
		expect( conn.socket_io ).to_not equal( io )
		conn.finish
	end

	it "consume_input should raise ConnectionBad for a closed connection" do
		serv = TCPServer.new( '127.0.0.1', 54320 )
		conn = described_class.connect_start( '127.0.0.1', 54320, "", "", "me", "xxxx", "somedb" )
		while [PG::CONNECTION_STARTED, PG::CONNECTION_MADE].include?(conn.connect_poll)
			sleep 0.1
		end
		serv.close
		expect{ conn.consume_input }.to raise_error(PG::ConnectionBad, /server closed the connection unexpectedly/){|err| expect(err).to have_attributes(connection: conn) }
		expect{ conn.consume_input }.to raise_error(PG::ConnectionBad, /can't get socket descriptor|connection not open/){|err| expect(err).to have_attributes(connection: conn) }
	end

	describe :check_socket do
		it "does nothing if connection is OK" do
			expect( @conn.check_socket ).to be_nil
		end

		def wait_check_socket(conn)
			retries = 100
			loop do
				conn.check_socket
				sleep 0.1
				break if (retries-=1) < 0
			end
		end

		it "raises error on broken connection" do
			conn = PG.connect(@conninfo)
			conn.send_query "SELECT pg_terminate_backend(pg_backend_pid())"
			expect do
				# Windows sometimes delivers the socket error prematurely in get_result, due a bug in the TCP stack
				expect( conn.get_result.result_status ).to be( PG::PGRES_FATAL_ERROR )

				wait_check_socket(conn)
			end.to raise_error(PG::ConnectionBad, /SSL connection has been closed unexpectedly|server closed the connection unexpectedly/)
		end

		it "processes messages before connection error" do
			conn = PG.connect(@conninfo)
			conn.send_query "do $$ BEGIN RAISE NOTICE 'foo'; PERFORM pg_terminate_backend(pg_backend_pid()); END; $$ LANGUAGE plpgsql;"

			expect do
				wait_check_socket(conn)
			end.to raise_error(PG::ConnectionBad, /SSL connection has been closed unexpectedly|server closed the connection unexpectedly/)
		end
	end

	it "calls the block supplied to wait_for_notify with the notify payload if it accepts " +
			"any number of arguments" do

		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN knees' )

		conn = described_class.connect( @conninfo )
		conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
		conn.finish

		event, pid, msg = nil
		@conn.wait_for_notify( 10 ) do |*args|
			event, pid, msg = *args
		end
		@conn.exec( 'UNLISTEN knees' )

		expect( event ).to eq( 'knees' )
		expect( pid ).to be_a_kind_of( Integer )
		expect( msg ).to eq( 'skirt and boots' )
	end

	it "accepts nil as the timeout in #wait_for_notify " do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN knees' )

		conn = described_class.connect( @conninfo )
		conn.exec( %Q{NOTIFY knees} )
		conn.finish

		event, pid = nil
		@conn.wait_for_notify( nil ) do |*args|
			event, pid = *args
		end
		@conn.exec( 'UNLISTEN knees' )

		expect( event ).to eq( 'knees' )
		expect( pid ).to be_a_kind_of( Integer )
	end

	it "sends nil as the payload if the notification wasn't given one" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN knees' )

		conn = described_class.connect( @conninfo )
		conn.exec( %Q{NOTIFY knees} )
		conn.finish

		payload = :notnil
		@conn.wait_for_notify( nil ) do |*args|
			payload = args[ 2 ]
		end
		@conn.exec( 'UNLISTEN knees' )

		expect( payload ).to be_nil()
	end

	it "calls the block supplied to wait_for_notify with the notify payload if it accepts " +
			"two arguments" do

		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN knees' )

		conn = described_class.connect( @conninfo )
		conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
		conn.finish

		event, pid, msg = nil
		@conn.wait_for_notify( 10 ) do |arg1, arg2|
			event, pid, msg = arg1, arg2
		end
		@conn.exec( 'UNLISTEN knees' )

		expect( event ).to eq( 'knees' )
		expect( pid ).to be_a_kind_of( Integer )
		expect( msg ).to be_nil()
	end

	it "calls the block supplied to wait_for_notify with the notify payload if it " +
			"doesn't accept arguments" do

		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN knees' )

		conn = described_class.connect( @conninfo )
		conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
		conn.finish

		notification_received = false
		@conn.wait_for_notify( 10 ) do
			notification_received = true
		end
		@conn.exec( 'UNLISTEN knees' )

		expect( notification_received ).to be_truthy()
	end

	it "calls the block supplied to wait_for_notify with the notify payload if it accepts " +
			"three arguments" do

		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN knees' )

		conn = described_class.connect( @conninfo )
		conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
		conn.finish

		event, pid, msg = nil
		@conn.wait_for_notify( 10 ) do |arg1, arg2, arg3|
			event, pid, msg = arg1, arg2, arg3
		end
		@conn.exec( 'UNLISTEN knees' )

		expect( event ).to eq( 'knees' )
		expect( pid ).to be_a_kind_of( Integer )
		expect( msg ).to eq( 'skirt and boots' )
	end

	context "server ping", :without_transaction do

		it "pings successfully with connection string" do
			ping = described_class.ping(@conninfo)
			expect( ping ).to eq( PG::PQPING_OK )
		end

		it "pings using 7 arguments converted to strings" do
			ping = described_class.ping('localhost', @port, nil, nil, :test, nil, nil)
			expect( ping ).to eq( PG::PQPING_OK )
		end

		it "pings using a hash of connection parameters" do
			ping = described_class.ping(
				:host => 'localhost',
				:port => @port,
				:dbname => :test)
			expect( ping ).to eq( PG::PQPING_OK )
		end

		it "returns correct response when ping connection cannot be established" do
			ping = described_class.ping(
				:host => 'localhost',
				:port => 9999,
				:dbname => :test)
			expect( ping ).to eq( PG::PQPING_NO_RESPONSE )
		end

		it "returns error when ping connection arguments are wrong" do
			ping = described_class.ping('localhost', 'localhost', nil, nil, :test, nil, nil)
			expect( ping ).to_not eq( PG::PQPING_OK )
		end

		it "returns correct response when ping connection arguments are wrong" do
			ping = described_class.ping(
				:host => 'localhost',
				:invalid_option => 9999,
				:dbname => :test)
			expect( ping ).to eq( PG::PQPING_NO_ATTEMPT )
		end

	end

	describe "set_single_row_mode" do

		it "raises an error when called at the wrong time" do
			expect {
				@conn.set_single_row_mode
			}.to raise_error(PG::Error, /PQsetSingleRowMode/){|err| expect(err).to have_attributes(connection: @conn) }
		end

		it "should work in single row mode" do
			@conn.send_query( "SELECT generate_series(1,10)" )
			@conn.set_single_row_mode

			results = []
			loop do
				@conn.block
				res = @conn.get_result or break
				results << res
			end
			expect( results.length ).to eq( 11 )
			results[0..-2].each do |res|
				expect( res.result_status ).to eq( PG::PGRES_SINGLE_TUPLE )
				values = res.field_values('generate_series')
				expect( values.length ).to eq( 1 )
				expect( values.first.to_i ).to be > 0
			end
			expect( results.last.result_status ).to eq( PG::PGRES_TUPLES_OK )
			expect( results.last.ntuples ).to eq( 0 )
		end

		it "should receive rows before entire query is finished" do
			@conn.send_query( "SELECT generate_series(0,999), NULL UNION ALL SELECT 1000, pg_sleep(10);" )
			@conn.set_single_row_mode

			start_time = Time.now
			res = @conn.get_result
			res.check

			expect( (Time.now - start_time) ).to be < 9
			expect( res.values ).to eq([["0", nil]])
			@conn.cancel
		end

		it "should receive rows before entire query fails" do
			@conn.exec( "CREATE FUNCTION errfunc() RETURNS int AS $$ BEGIN RAISE 'test-error'; END; $$ LANGUAGE plpgsql;" )
			@conn.send_query( "SELECT generate_series(0,999), NULL UNION ALL SELECT 1000, errfunc();" )
			@conn.set_single_row_mode

			first_result = nil
			expect do
				loop do
					res = @conn.get_result or break
					res.check
					first_result ||= res
				end
			end.to raise_error(PG::Error){|err| expect(err).to have_attributes(connection: @conn) }
			expect( first_result.kind_of?(PG::Result) ).to be_truthy
			expect( first_result.result_status ).to eq( PG::PGRES_SINGLE_TUPLE )
		end

	end

	describe "set_chunked_rows_mode", :postgresql_17 do

		it "raises an error when called at the wrong time" do
			expect {
				@conn.set_chunked_rows_mode(2)
			}.to raise_error(PG::Error, /PQsetChunkedRowsMode/){|err| expect(err).to have_attributes(connection: @conn) }
		end

		it "raises an error when called with wrong arguments" do
			expect { @conn.set_chunked_rows_mode(:nonint) }.to raise_error(TypeError)
			expect { @conn.set_chunked_rows_mode(0) }.to raise_error(PG::Error, /PQsetChunkedRowsMode/)
			expect { @conn.set_chunked_rows_mode(-2) }.to raise_error(PG::Error)
		end

		it "should work in single row mode" do
			@conn.send_query( "SELECT generate_series(1,12)" )
			@conn.set_chunked_rows_mode(3)

			results = []
			loop do
				@conn.block
				res = @conn.get_result or break
				results << res
			end
			expect( results.length ).to eq( 5 )
			results[0..-2].each do |res|
				expect( res.result_status ).to eq( PG::PGRES_TUPLES_CHUNK )
				values = res.field_values('generate_series')
				expect( values.length ).to eq( 3 )
				expect( values.first.to_i ).to be > 0
			end
			expect( results.last.result_status ).to eq( PG::PGRES_TUPLES_OK )
			expect( results.last.ntuples ).to eq( 0 )
		end

		it "should receive rows before entire query is finished" do
			@conn.send_query( "SELECT generate_series(0,999), NULL UNION ALL SELECT 1000, pg_sleep(10);" )
			@conn.set_chunked_rows_mode(4)

			start_time = Time.now
			res = @conn.get_result
			res.check

			expect( (Time.now - start_time) ).to be < 9
			expect( res.values ).to eq([["0", nil], ["1", nil], ["2", nil], ["3", nil]])
			@conn.cancel
		end

		it "should receive rows before entire query fails" do
			@conn.exec( "CREATE FUNCTION errfunc() RETURNS int AS $$ BEGIN RAISE 'test-error'; END; $$ LANGUAGE plpgsql;" )
			@conn.send_query( "SELECT generate_series(0,999), NULL UNION ALL SELECT 1000, errfunc();" )
			@conn.set_chunked_rows_mode(5)

			first_result = nil
			expect do
				loop do
					res = @conn.get_result or break
					res.check
					first_result ||= res
				end
			end.to raise_error(PG::Error){|err| expect(err).to have_attributes(connection: @conn) }
			expect( first_result.kind_of?(PG::Result) ).to be_truthy
			expect( first_result.result_status ).to eq( PG::PGRES_TUPLES_CHUNK )
		end

	end

	context "pipeline mode", :postgresql_14 do

		describe "pipeline_status" do
			it "can enter and exit the pipeline mode" do
				@conn.enter_pipeline_mode
				expect( @conn.pipeline_status ).to eq( PG::PQ_PIPELINE_ON )
				@conn.exit_pipeline_mode
				expect( @conn.pipeline_status ).to eq( PG::PQ_PIPELINE_OFF )
			end
		end

		describe "enter_pipeline_mode" do
			it "does nothing if already in pipeline mode" do
				@conn.enter_pipeline_mode
				@conn.enter_pipeline_mode
				expect( @conn.pipeline_status ).to eq( PG::PQ_PIPELINE_ON )
			end

			it "raises an error when called with pending results" do
				@conn.send_query_params "select 1", []
				expect {
					@conn.enter_pipeline_mode
				}.to raise_error(PG::Error){|err| expect(err).to have_attributes(connection: @conn) }
				@conn.get_last_result
			end
		end

		describe "exit_pipeline_mode" do
			it "does nothing if not in pipeline mode" do
				@conn.exit_pipeline_mode
				expect( @conn.pipeline_status ).to eq( PG::PQ_PIPELINE_OFF )
			end

			it "raises an error when called with pending results" do
				@conn.enter_pipeline_mode
				@conn.send_query_params "select 1", []
				expect {
					@conn.exit_pipeline_mode
				}.to raise_error(PG::Error){|err| expect(err).to have_attributes(connection: @conn) }
				@conn.pipeline_sync
				@conn.get_last_result
			end
		end

		describe "pipeline_sync" do
			it "sends a sync message" do
				@conn.enter_pipeline_mode
				@conn.send_query_params "select 6", []
				@conn.pipeline_sync
				expect( @conn.get_result.result_status ).to eq( PG::PGRES_TUPLES_OK )
				expect( @conn.get_result ).to be_nil
				expect( @conn.get_result.result_status ).to eq( PG::PGRES_PIPELINE_SYNC )
				expect( @conn.get_result ).to be_nil
				expect( @conn.get_result ).to be_nil
				@conn.exit_pipeline_mode
			end

			it "raises an error when not in pipeline mode" do
				expect {
					@conn.pipeline_sync
				}.to raise_error(PG::Error){|err| expect(err).to have_attributes(connection: @conn) }
			end

			it "has send_pipeline_sync method", :postgresql_17 do
				expect( @conn.respond_to?(:send_pipeline_sync) ).to be_truthy
				expect( @conn.respond_to?(:async_pipeline_sync) ).to be_truthy
			end
		end

		describe "send_flush_request" do
			it "flushes all results" do
				@conn.enter_pipeline_mode
				@conn.send_query_params "select 1", []
				@conn.send_flush_request
				@conn.flush
				expect( @conn.get_result.result_status ).to eq( PG::PGRES_TUPLES_OK )
				expect( @conn.get_result ).to be_nil
				expect( @conn.get_result ).to be_nil
			end

			it "raises an error when called with pending results" do
				@conn.send_query_params "select 1", []
				expect {
					@conn.send_flush_request
				}.to raise_error(PG::Error){|err| expect(err).to have_attributes(connection: @conn) }
			end
		end

		describe "get_last_result" do
			it "delivers PGRES_PIPELINE_SYNC" do
				@conn.enter_pipeline_mode
				@conn.send_query_params "select 6", []
				@conn.pipeline_sync
				expect( @conn.get_last_result.values ).to eq( [["6"]] )
				expect( @conn.get_last_result.result_status ).to eq( PG::PGRES_PIPELINE_SYNC )
				@conn.exit_pipeline_mode
			end

			it "raises an error for PGRES_PIPELINE_ABORT" do
				@conn.enter_pipeline_mode
				@conn.send_query_params("garbage", [])
				@conn.send_query_params("SELECT 7", [])
				@conn.pipeline_sync
				begin
					@conn.get_last_result
				rescue PG::SyntaxError => err1
				end
				expect( err1.result.result_status ).to eq( PG::PGRES_FATAL_ERROR )
				begin
					@conn.get_last_result
				rescue PG::UnableToSend => err2
				end
				expect( err2.result.result_status ).to eq( PG::PGRES_PIPELINE_ABORTED )
				expect( @conn.pipeline_status ).to eq( PG::PQ_PIPELINE_ABORTED )
				expect( @conn.get_last_result.result_status ).to eq( PG::PGRES_PIPELINE_SYNC )
				@conn.exit_pipeline_mode
			end
		end
	end

	context "multinationalization support" do

		describe "rubyforge #22925: m17n support" do
			it "should return results in the same encoding as the client (iso-8859-1)" do
				@conn.internal_encoding = 'iso8859-1'
				res = @conn.exec_params("VALUES ('fantasia')", [], 0)
				out_string = res[0]['column1']
				expect( out_string ).to eq( 'fantasia' )
				expect( out_string.encoding ).to eq( Encoding::ISO8859_1 )
			end

			it "should return results in the same encoding as the client (utf-8)" do
				@conn.internal_encoding = 'utf-8'
				res = @conn.exec_params("VALUES ('世界線航跡蔵')", [], 0)
				out_string = res[0]['column1']
				expect( out_string ).to eq( '世界線航跡蔵' )
				expect( out_string.encoding ).to eq( Encoding::UTF_8 )
			end

			it "should return results in the same encoding as the client (EUC-JP)" do
				@conn.internal_encoding = 'EUC-JP'
				stmt = "VALUES ('世界線航跡蔵')".encode('EUC-JP')
				res = @conn.exec_params(stmt, [], 0)
				out_string = res[0]['column1']
				expect( out_string ).to eq( '世界線航跡蔵'.encode('EUC-JP') )
				expect( out_string.encoding ).to eq( Encoding::EUC_JP )
			end

			it "returns the results in the correct encoding even if the client_encoding has " +
			   "changed since the results were fetched" do
				@conn.internal_encoding = 'EUC-JP'
				stmt = "VALUES ('世界線航跡蔵')".encode('EUC-JP')
				res = @conn.exec_params(stmt, [], 0)
				@conn.internal_encoding = 'utf-8'
				out_string = res[0]['column1']
				expect( out_string ).to eq( '世界線航跡蔵'.encode('EUC-JP') )
				expect( out_string.encoding ).to eq( Encoding::EUC_JP )
			end

			it "the connection should return ASCII-8BIT when it's set to SQL_ASCII" do
				@conn.exec "SET client_encoding TO SQL_ASCII"
				expect( @conn.internal_encoding ).to eq( Encoding::ASCII_8BIT )
			end

			it "the connection should use the BINARY encoding when it's set to JOHAB" do
				@conn.set_client_encoding "JOHAB"
				val = @conn.exec("SELECT chr(x'3391'::int)").values[0][0]
				expect( val.encoding ).to eq( Encoding::BINARY )
				expect( val.unpack("H*")[0] ).to eq( "dc65" )
			end

			it "can retrieve server encoding as text" do
				enc = @conn.parameter_status "server_encoding"
				expect( enc ).to eq( "UTF8" )
			end

			it "can retrieve server encoding as ruby encoding" do
				expect( @conn.external_encoding ).to eq( Encoding::UTF_8 )
			end

			it "uses the client encoding for escaped string" do
				original = "Möhre to 'scape".encode( "utf-16be" )
				@conn.set_client_encoding( "euc_jp" )
				escaped  = @conn.escape( original )
				expect( escaped.encoding ).to eq( Encoding::EUC_JP )
				expect( escaped ).to eq( "Möhre to ''scape".encode(Encoding::EUC_JP) )
			end

			it "uses the client encoding for escaped literal" do
				original = "Möhre to 'scape".encode( "utf-16be" )
				@conn.set_client_encoding( "euc_jp" )
				escaped  = @conn.escape_literal( original )
				expect( escaped.encoding ).to eq( Encoding::EUC_JP )
				expect( escaped ).to eq( "'Möhre to ''scape'".encode(Encoding::EUC_JP) )
			end

			it "uses the client encoding for escaped identifier" do
				original = "Möhre to 'scape".encode( "utf-16le" )
				@conn.set_client_encoding( "euc_jp" )
				escaped  = @conn.escape_identifier( original )
				expect( escaped.encoding ).to eq( Encoding::EUC_JP )
				expect( escaped ).to eq( "\"Möhre to 'scape\"".encode(Encoding::EUC_JP) )
			end

			it "uses the client encoding for quote_ident" do
				original = "Möhre to 'scape".encode( "utf-16le" )
				@conn.set_client_encoding( "euc_jp" )
				escaped  = @conn.quote_ident( original )
				expect( escaped.encoding ).to eq( Encoding::EUC_JP )
				expect( escaped ).to eq( "\"Möhre to 'scape\"".encode(Encoding::EUC_JP) )
			end

			it "uses the previous string encoding for escaped string" do
				original = "Möhre to 'scape".encode( "iso-8859-1" )
				@conn.set_client_encoding( "euc_jp" )
				escaped  = described_class.escape( original )
				expect( escaped.encoding ).to eq( Encoding::ISO8859_1 )
				expect( escaped ).to eq( "Möhre to ''scape".encode(Encoding::ISO8859_1) )
			end

			it "uses the previous string encoding for quote_ident" do
				original = "Möhre to 'scape".encode( "iso-8859-1" )
				@conn.set_client_encoding( "euc_jp" )
				escaped  = described_class.quote_ident( original )
				expect( escaped.encoding ).to eq( Encoding::ISO8859_1 )
				expect( escaped.encode ).to eq( "\"Möhre to 'scape\"".encode(Encoding::ISO8859_1) )
			end

			it "raises appropriate error if set_client_encoding is called with invalid arguments" do
				expect { @conn.set_client_encoding( "invalid" ) }.to raise_error(PG::Error, /invalid value/){|err| expect(err).to have_attributes(connection: @conn) }
				expect { @conn.set_client_encoding( :invalid ) }.to raise_error(TypeError)
				expect { @conn.set_client_encoding( nil ) }.to raise_error(TypeError)
			end

		end

		describe "respect and convert character encoding of input strings" do
			before :each do
				@conn.internal_encoding = __ENCODING__
			end

			it "should convert query string and parameters to #exec_params" do
				r = @conn.exec_params("VALUES( $1, $2, $1=$2, 'grün')".encode("utf-16le"),
				                  ['grün'.encode('utf-16be'), 'grün'.encode('iso-8859-1')])
				expect( r.values ).to eq( [['grün', 'grün', 't', 'grün']] )
			end

			it "should convert query string to #exec" do
				r = @conn.exec("SELECT 'grün'".encode("utf-16be"))
				expect( r.values ).to eq( [['grün']] )
			end

			it "should convert strings and parameters to #prepare and #exec_prepared" do
				@conn.prepare("weiß1".encode("utf-16be"), "VALUES( $1, $2, $1=$2, 'grün')".encode("cp850"))
				r = @conn.exec_prepared("weiß1".encode("utf-32le"),
				                ['grün'.encode('cp936'), 'grün'.encode('utf-16le')])
				expect( r.values ).to eq( [['grün', 'grün', 't', 'grün']] )
			end

			it "should convert strings to #describe_prepared" do
				@conn.prepare("weiß2", "VALUES(123)")
				r = @conn.describe_prepared("weiß2".encode("utf-16be"))
				expect( r.nfields ).to eq( 1 )
				expect { @conn.prepare("weiß2", "VALUES(123)") }.to raise_error(PG::DuplicatePstatement)
			end

			it "should convert strings to #describe_portal" do
				@conn.exec "DECLARE cörsör CURSOR FOR VALUES(1,2,3)"
				r = @conn.describe_portal("cörsör".encode("utf-16le"))
				expect( r.nfields ).to eq( 3 )
			end

			it "should convert strings to #close_prepared", :postgresql_17 do
				@conn.prepare("weiß5", "VALUES(123)")
				r = @conn.close_prepared("weiß5".encode("utf-16be"))
				expect( r.nfields ).to eq( 0 )
				@conn.prepare("weiß5", "VALUES(123)")
				r = @conn.close_prepared("weiß5".encode("utf-16be"))
			end

			it "should convert strings to #close_portal", :postgresql_17 do
				@conn.exec "DECLARE cörsör5 CURSOR FOR VALUES(1,2,3)"
				r = @conn.close_portal("cörsör5".encode("utf-16le"))
				expect( r.nfields ).to eq( 0 )
				@conn.exec "DECLARE cörsör5 CURSOR FOR VALUES(1,2,3)"
				r = @conn.close_portal("cörsör5".encode("utf-16le"))
			end

			it "should convert query string to #send_query" do
				@conn.send_query("VALUES('grün')".encode("utf-16be"))
				expect( @conn.get_last_result.values ).to eq( [['grün']] )
			end

			it "should convert query string and parameters to #send_query_params" do
				@conn.send_query_params("VALUES( $1, $2, $1=$2, 'grün')".encode("utf-16le"),
				                  ['grün'.encode('utf-32be'), 'grün'.encode('iso-8859-1')])
				expect( @conn.get_last_result.values ).to eq( [['grün', 'grün', 't', 'grün']] )
			end

			it "should convert strings and parameters to #send_prepare and #send_query_prepared" do
				@conn.send_prepare("weiß3".encode("iso-8859-1"), "VALUES( $1, $2, $1=$2, 'grün')".encode("utf-16be"))
				@conn.get_last_result
				@conn.send_query_prepared("weiß3".encode("utf-32le"),
				                ['grün'.encode('utf-16le'), 'grün'.encode('iso-8859-1')])
				expect( @conn.get_last_result.values ).to eq( [['grün', 'grün', 't', 'grün']] )
			end

			it "should convert strings to #send_describe_prepared" do
				@conn.prepare("weiß4", "VALUES(123)")
				@conn.send_describe_prepared("weiß4".encode("utf-16be"))
				expect( @conn.get_last_result.nfields ).to eq( 1 )
			end

			it "should convert strings to #send_describe_portal" do
				@conn.exec "DECLARE cörsör CURSOR FOR VALUES(1,2,3)"
				@conn.send_describe_portal("cörsör".encode("utf-16le"))
				expect( @conn.get_last_result.nfields ).to eq( 3 )
			end

			it "should convert error string to #put_copy_end" do
				@conn.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
				@conn.exec( "COPY copytable FROM STDIN" )
				@conn.put_copy_end("grün".encode("utf-16be"))
				expect( @conn.get_result.error_message ).to match(/grün/)
				@conn.get_result
			end
		end

		it "rejects command strings with zero bytes" do
			expect{ @conn.exec( "SELECT 1;\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.exec_params( "SELECT 1;\x00", [] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.prepare( "abc\x00", "SELECT 1;" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.prepare( "abc", "SELECT 1;\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.exec_prepared( "abc\x00", [] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.describe_prepared( "abc\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.describe_portal( "abc\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_query( "SELECT 1;\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_query_params( "SELECT 1;\x00", [] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_prepare( "abc\x00", "SELECT 1;" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_prepare( "abc", "SELECT 1;\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_query_prepared( "abc\x00", [] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_describe_prepared( "abc\x00" ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_describe_portal( "abc\x00" ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "rejects query params with zero bytes" do
			expect{ @conn.exec_params( "SELECT 1;\x00", ["ab\x00"] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.exec_prepared( "abc\x00", ["ab\x00"] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_query_params( "SELECT 1;\x00", ["ab\x00"] ) }.to raise_error(ArgumentError, /null byte/)
			expect{ @conn.send_query_prepared( "abc\x00", ["ab\x00"] ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "rejects string with zero bytes in escape" do
			expect{ @conn.escape( "ab\x00cd" ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "rejects string with zero bytes in escape_literal" do
			expect{ @conn.escape_literal( "ab\x00cd" ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "rejects string with zero bytes in escape_identifier" do
			expect{ @conn.escape_identifier( "ab\x00cd" ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "rejects string with zero bytes in quote_ident" do
			expect{ described_class.quote_ident( "ab\x00cd" ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "rejects Array with string with zero bytes" do
			original = ["xyz", "2\x00"]
			expect{ described_class.quote_ident( original ) }.to raise_error(ArgumentError, /null byte/)
		end

		it "can quote bigger strings with quote_ident" do
			original = "'01234567\"" * 100
			escaped = described_class.quote_ident( original )
			expect( escaped ).to eq( "\"" + original.gsub("\"", "\"\"") + "\"" )
		end

		it "can quote Arrays with quote_ident" do
			original = "'01234567\""
			escaped = described_class.quote_ident( [original]*3 )
			expected = ["\"" + original.gsub("\"", "\"\"") + "\""] * 3
			expect( escaped ).to eq( expected.join(".") )
		end

		it "will raise a TypeError for invalid arguments to quote_ident" do
			expect{ described_class.quote_ident( nil ) }.to raise_error(TypeError)
			expect{ described_class.quote_ident( [nil] ) }.to raise_error(TypeError)
			expect{ described_class.quote_ident( [['a']] ) }.to raise_error(TypeError)
		end

		describe "Ruby 1.9.x default_internal encoding" do

			it "honors the Encoding.default_internal if it's set and the synchronous interface is used", :without_transaction do
				@conn.transaction do |txn_conn|
					txn_conn.internal_encoding = Encoding::ISO8859_1
					txn_conn.exec( "CREATE TABLE defaultinternaltest ( foo text )" )
					txn_conn.exec( "INSERT INTO defaultinternaltest VALUES ('Grün und Weiß')" )
				end

				begin
					prev_encoding = Encoding.default_internal
					Encoding.default_internal = Encoding::ISO8859_2

					conn = PG.connect( @conninfo )
					expect( conn.internal_encoding ).to eq( Encoding::ISO8859_2 )
					res = conn.exec( "SELECT foo FROM defaultinternaltest" )
					expect( res[0]['foo'].encoding ).to eq( Encoding::ISO8859_2 )
				ensure
					conn.exec( "DROP TABLE defaultinternaltest" )
					conn.finish if conn
					Encoding.default_internal = prev_encoding
				end
			end

			it "doesn't change anything if Encoding.default_internal it set to DB default encoding", :without_transaction do
				begin
					prev_encoding = Encoding.default_internal
					Encoding.default_internal = Encoding::UTF_8

					# PG.connect shouldn't emit a "set client_encoding" for UTF_8, since the server is already on UTF8.
					conn = PG.connect( @conninfo )
					expect( conn.internal_encoding ).to eq( Encoding::UTF_8 )
					res = conn.exec( "SELECT setting, source FROM pg_settings WHERE name='client_encoding'" )
					expect( res[0].values ).to eq( ['UTF8', 'default'] )
				ensure
					conn.finish if conn
					Encoding.default_internal = prev_encoding
				end
			end

			it "allows users of the async interface to set the client_encoding to the default_internal" do
				begin
					prev_encoding = Encoding.default_internal
					Encoding.default_internal = Encoding::KOI8_R

					@conn.set_default_encoding

					expect( @conn.internal_encoding ).to eq( Encoding::KOI8_R )
				ensure
					Encoding.default_internal = prev_encoding
				end
			end

		end


		it "encodes exception messages with the connection's encoding (#96)", :without_transaction do
			# Use a new connection so the client_encoding isn't set outside of this example
			conn = PG.connect( @conninfo )
			conn.client_encoding = 'iso-8859-15'

			conn.transaction do
				conn.exec "CREATE TABLE foo (bar TEXT)"

				begin
					query = "INSERT INTO foo VALUES ('Côte d'Ivoire')".encode( 'iso-8859-15' )
					conn.exec( query )
				rescue => err
					expect( err.message.encoding ).to eq( Encoding::ISO8859_15 )
				else
					fail "No exception raised?!"
				end
			end

			conn.finish if conn
		end

		it "handles clearing result in or after set_notice_receiver" do
			r = nil
			@conn.set_notice_receiver do |result|
				r = result
				expect( r.cleared? ).to eq(false)
			end
			@conn.exec "do $$ BEGIN RAISE NOTICE 'foo'; END; $$ LANGUAGE plpgsql;"
			sleep 0.2
			expect( r ).to be_a( PG::Result )
			expect( r.cleared? ).to eq(true)
			expect( r.autoclear? ).to eq(true)
			r.clear
			@conn.set_notice_receiver
		end

		it "receives properly encoded messages in the notice callbacks" do
			[:receiver, :processor].each do |kind|
				notices = []
				@conn.internal_encoding = 'utf-8'
				if kind == :processor
					@conn.set_notice_processor do |msg|
						notices << msg
					end
				else
					@conn.set_notice_receiver do |result|
						notices << result.error_message
					end
				end

				3.times do
					@conn.exec "do $$ BEGIN RAISE NOTICE '世界線航跡蔵'; END; $$ LANGUAGE plpgsql;"
				end

				expect( notices.length ).to eq( 3 )
				notices.each do |notice|
					expect( notice ).to match( /^NOTICE:.*世界線航跡蔵/ )
					expect( notice.encoding ).to eq( Encoding::UTF_8 )
				end
				@conn.set_notice_receiver
				@conn.set_notice_processor
			end
		end

		it "receives properly encoded text from wait_for_notify", :without_transaction do
			@conn.internal_encoding = 'utf-8'
			@conn.exec( 'LISTEN "Möhre"' )
			@conn.exec( %Q{NOTIFY "Möhre", '世界線航跡蔵'} )
			event, pid, msg = nil
			@conn.wait_for_notify( 10 ) do |*args|
				event, pid, msg = *args
			end
			@conn.exec( 'UNLISTEN "Möhre"' )

			expect( event ).to eq( "Möhre" )
			expect( event.encoding ).to eq( Encoding::UTF_8 )
			expect( pid ).to be_a_kind_of(Integer)
			expect( msg ).to eq( '世界線航跡蔵' )
			expect( msg.encoding ).to eq( Encoding::UTF_8 )
		end

		it "returns properly encoded text from notifies", :without_transaction do
			@conn.internal_encoding = 'utf-8'
			@conn.exec( 'LISTEN "Möhre"' )
			@conn.exec( %Q{NOTIFY "Möhre", '世界線航跡蔵'} )
			@conn.exec( 'UNLISTEN "Möhre"' )

			notification = @conn.notifies
			expect( notification[:relname] ).to eq( "Möhre" )
			expect( notification[:relname].encoding ).to eq( Encoding::UTF_8 )
			expect( notification[:extra] ).to eq( '世界線航跡蔵' )
			expect( notification[:extra].encoding ).to eq( Encoding::UTF_8 )
			expect( notification[:be_pid] ).to be > 0
		end
	end

	describe "type casting" do
		it "should raise an error on invalid param mapping" do
			expect{
				@conn.exec_params( "SELECT 1", [], nil, :invalid )
			}.to raise_error(TypeError)
		end

		it "should return nil if no type mapping is set" do
			expect( @conn.type_map_for_queries ).to be_kind_of(PG::TypeMapAllStrings)
			expect( @conn.type_map_for_results ).to be_kind_of(PG::TypeMapAllStrings)
		end

		it "shouldn't type map params unless requested" do
			if @conn.server_version < 100000
				expect{
					@conn.exec_params( "SELECT $1", [5] )
				}.to raise_error(PG::IndeterminateDatatype){|err| expect(err).to have_attributes(connection: @conn) }
			else
				# PostgreSQL-10 maps to TEXT type (OID 25)
				expect( @conn.exec_params( "SELECT $1", [5] ).ftype(0)).to eq(25)
			end
		end

		it "should raise an error on invalid encoder to put_copy_data" do
			expect{
				@conn.put_copy_data [1], :invalid
			}.to raise_error(TypeError)
		end

		it "can type cast parameters to put_copy_data with explicit encoder" do
			tm = PG::TypeMapByColumn.new [nil]
			row_encoder = PG::TextEncoder::CopyRow.new type_map: tm

			@conn.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
			@conn.copy_data( "COPY copytable FROM STDOUT" ) do |res|
				@conn.put_copy_data [1], row_encoder
				@conn.put_copy_data ["2"], row_encoder
			end

			@conn.copy_data( "COPY copytable FROM STDOUT", row_encoder ) do |res|
				@conn.put_copy_data [3]
				@conn.put_copy_data ["4"]
			end

			res = @conn.exec( "SELECT * FROM copytable ORDER BY col1" )
			expect( res.values ).to eq( [["1"], ["2"], ["3"], ["4"]] )
		end

		context "with default query type map" do
			before :each do
				@conn2 = described_class.new(@conninfo)
				tm = PG::TypeMapByClass.new
				tm[Integer] = PG::TextEncoder::Integer.new oid: 20
				@conn2.type_map_for_queries = tm

				row_encoder = PG::TextEncoder::CopyRow.new type_map: tm
				@conn2.encoder_for_put_copy_data = row_encoder
			end
			after :each do
				@conn2.close
			end

			it "should respect a type mapping for params and it's OID and format code" do
				res = @conn2.exec_params( "SELECT $1", [5] )
				expect( res.values ).to eq( [["5"]] )
				expect( res.ftype(0) ).to eq( 20 )
			end

			it "should return the current type mapping" do
				expect( @conn2.type_map_for_queries ).to be_kind_of(PG::TypeMapByClass)
			end

			it "should work with arbitrary number of params in conjunction with type casting" do
				begin
					3.step( 12, 0.2 ) do |exp|
						num_params = (2 ** exp).to_i
						sql = num_params.times.map{|n| "$#{n+1}" }.join(",")
						params = num_params.times.to_a
						res = @conn2.exec_params( "SELECT #{sql}", params )
						expect( res.nfields ).to eq( num_params )
						expect( res.values ).to eq( [num_params.times.map(&:to_s)] )
					end
				rescue PG::ProgramLimitExceeded
					# Stop silently as soon the server complains about too many params
				end
			end

			it "can process #copy_data input queries with row encoder and respects character encoding" do
				@conn2.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
				@conn2.copy_data( "COPY copytable FROM STDOUT" ) do |res|
					@conn2.put_copy_data [1]
					@conn2.put_copy_data ["Möhre".encode("utf-16le")]
				end

				res = @conn2.exec( "SELECT * FROM copytable ORDER BY col1" )
				expect( res.values ).to eq( [["1"], ["Möhre"]] )
			end
		end

		context "with default result type map" do
			before :each do
				@conn2 = described_class.new(@conninfo)
				tm = PG::TypeMapByOid.new
				tm.add_coder PG::TextDecoder::Integer.new oid: 23, format: 0
				@conn2.type_map_for_results = tm

				row_decoder = PG::TextDecoder::CopyRow.new
				@conn2.decoder_for_get_copy_data = row_decoder
			end
			after :each do
				@conn2.close
			end

			it "should respect a type mapping for result" do
				res = @conn2.exec_params( "SELECT $1::INT", ["5"] )
				expect( res.values ).to eq( [[5]] )
			end

			it "should return the current type mapping" do
				expect( @conn2.type_map_for_results ).to be_kind_of(PG::TypeMapByOid)
			end

			it "should work with arbitrary number of params in conjunction with type casting" do
				begin
					3.step( 12, 0.2 ) do |exp|
						num_params = (2 ** exp).to_i
						sql = num_params.times.map{|n| "$#{n+1}::INT" }.join(",")
						params = num_params.times.to_a
						res = @conn2.exec_params( "SELECT #{sql}", params )
						expect( res.nfields ).to eq( num_params )
						expect( res.values ).to eq( [num_params.times.to_a] )
					end
				rescue PG::ProgramLimitExceeded
					# Stop silently as soon the server complains about too many params
				end
			end

			it "can process #copy_data output with row decoder and respects character encoding" do
				@conn2.internal_encoding = Encoding::ISO8859_1
				rows = []
				@conn2.copy_data( "COPY (VALUES('1'), ('Möhre')) TO STDOUT".encode("utf-16le") ) do |res|
					while row=@conn2.get_copy_data
						rows << row
					end
				end
				expect( rows.last.last.encoding ).to eq( Encoding::ISO8859_1 )
				expect( rows ).to eq( [["1"], ["Möhre".encode("iso-8859-1")]] )
			end

			it "can type cast #copy_data output with explicit decoder" do
				tm = PG::TypeMapByColumn.new [PG::TextDecoder::Integer.new]
				row_decoder = PG::TextDecoder::CopyRow.new type_map: tm
				rows = []
				@conn.copy_data( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT", row_decoder ) do |res|
					while row=@conn.get_copy_data
						rows << row
					end
				end
				@conn.copy_data( "COPY (SELECT 3 UNION ALL SELECT 4) TO STDOUT" ) do |res|
					while row=@conn.get_copy_data( false, row_decoder )
						rows << row
					end
				end
				expect( rows ).to eq( [[1], [2], [3], [4]] )
			end
		end
	end

	describe :field_name_type do
		before :each do
			@conn2 = PG.connect(@conninfo)
		end
		after :each do
			@conn2.close
		end

		it "uses string field names per default" do
			expect(@conn2.field_name_type).to eq(:string)
		end

		it "can set string field names" do
			@conn2.field_name_type = :string
			expect(@conn2.field_name_type).to eq(:string)
			res = @conn2.exec("SELECT 1 as az")
			expect(res.field_name_type).to eq(:string)
			expect(res.fields).to eq(["az"])
		end

		it "can set symbol field names" do
			@conn2.field_name_type = :symbol
			expect(@conn2.field_name_type).to eq(:symbol)
			res = @conn2.exec("SELECT 1 as az")
			expect(res.field_name_type).to eq(:symbol)
			expect(res.fields).to eq([:az])
		end

		it "can't set invalid values" do
			expect{ @conn2.field_name_type = :sym }.to raise_error(ArgumentError, /invalid argument :sym/)
			expect{ @conn2.field_name_type = "symbol" }.to raise_error(ArgumentError, /invalid argument "symbol"/)
		end
	end

	describe "deprecated forms of methods" do
		if PG::VERSION < "2"
			it "should forward exec to exec_params" do
				res = @conn.exec("VALUES($1::INT)", [7]).values
				expect(res).to eq( [["7"]] )
				res = @conn.exec("VALUES($1::INT)", [7], 1).values
				expect(res).to eq( [[[7].pack("N")]] )
				res = @conn.exec("VALUES(8)", [], 1).values
				expect(res).to eq( [[[8].pack("N")]] )
			end

			it "should forward exec_params to exec" do
				res = @conn.exec_params("VALUES(3); VALUES(4)").values
				expect(res).to eq( [["4"]] )
				res = @conn.exec_params("VALUES(3); VALUES(4)", nil).values
				expect(res).to eq( [["4"]] )
				res = @conn.exec_params("VALUES(3); VALUES(4)", nil, nil).values
				expect(res).to eq( [["4"]] )
				res = @conn.exec_params("VALUES(3); VALUES(4)", nil, 1).values
				expect(res).to eq( [["4"]] )
				res = @conn.exec_params("VALUES(3); VALUES(4)", nil, nil, nil).values
				expect(res).to eq( [["4"]] )
				expect{
					@conn.exec_params("VALUES(3); VALUES(4)", nil, nil, nil, nil).values
				}.to raise_error(ArgumentError)
			end

			it "should forward send_query to send_query_params" do
				@conn.send_query("VALUES($1)", [5])
				expect(@conn.get_last_result.values).to eq( [["5"]] )
			end

			it "should respond_to socket", :unix do
				expect( @conn.socket ).to eq( @conn.socket_io.fileno )
			end
		else
			# Method forwarding removed by PG::VERSION >= "2"
			it "shouldn't forward exec to exec_params" do
				expect do
					@conn.exec("VALUES($1::INT)", [7])
				end.to raise_error(ArgumentError)
			end

			it "shouldn't forward exec_params to exec" do
				expect do
					@conn.exec_params("VALUES(3); VALUES(4)")
				end.to raise_error(ArgumentError)
			end

			it "shouldn't forward send_query to send_query_params" do
				expect do
					@conn.send_query("VALUES($1)", [5])
				end.to raise_error(ArgumentError)
			end

			it "shouldn't forward async_exec_params to async_exec" do
				expect do
					@conn.async_exec_params("VALUES(1)")
				end.to raise_error(ArgumentError)
			end

			it "shouldn't respond_to socket" do
				expect do
					@conn.socket
				end.to raise_error(ArgumentError)
			end
		end

		it "shouldn't forward send_query_params to send_query" do
			expect{ @conn.send_query_params("VALUES(4)").values }
				.to raise_error(ArgumentError)
			expect{ @conn.send_query_params("VALUES(4)", nil).values }
				.to raise_error(TypeError)
		end
	end
end
