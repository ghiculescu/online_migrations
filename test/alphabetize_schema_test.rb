# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class AlphabetizeSchemaTest < Minitest::Test
  def setup
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:users, force: true) do |t|
      t.string :name
      t.string :city
    end
  end

  def teardown
    @connection.drop_table(:users) rescue nil
  end

  def test_default
    schema = dump_schema

    expected_columns = <<-RUBY
    t.string "name"
    t.string "city"
    RUBY
    assert_match expected_columns, schema
  end

  def test_enabled
    schema = OnlineMigrations.config.stub(:alphabetize_schema, true) do
      dump_schema
    end

    expected_columns = <<-RUBY
    t.string "city"
    t.string "name"
    RUBY
    assert_match expected_columns, schema
  end

  private
    def dump_schema
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.string
    end
end