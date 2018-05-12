# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

context "running with async_* methods" do
	redirect_methods = {
		:async_exec => :exec,
	}

	before :each do
		PG::Connection.class_eval do
			redirect_methods.each do |async, sync|
				alias_method "sync_#{sync}", sync
				remove_method sync
				alias_method sync, async
			end
		end
	end

	after :each do
		PG::Connection.class_eval do
			redirect_methods.each do |async, sync|
				remove_method sync
				alias_method sync, "sync_#{sync}"
				remove_method "sync_#{sync}"
			end
		end
	end

	fname = File.expand_path("../connection_spec.rb", __FILE__)
	eval File.read(fname), binding, fname
end
