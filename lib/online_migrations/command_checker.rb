# frozen_string_literal: true

require "erb"
require "openssl"
require "set"

module OnlineMigrations
  # @private
  class CommandChecker
    attr_accessor :direction

    def initialize(migration)
      @migration = migration
      @safe = false
      @foreign_key_tables = Set.new
    end

    def safety_assured
      @prev_value = @safe
      @safe = true
      yield
    ensure
      @safe = @prev_value
    end

    def check(command, *args, &block)
      unless safe?
        do_check(command, *args, &block)

        if @foreign_key_tables.count > 1
          raise_error :multiple_foreign_keys
        end
      end

      true
    end

    private
      def safe?
        @safe ||
          ENV["SAFETY_ASSURED"] ||
          (direction == :down && !OnlineMigrations.config.check_down) ||
          version <= OnlineMigrations.config.start_after
      end

      def version
        @migration.version || @migration.class.version
      end

      def do_check(command, *args, **options, &block)
        case command
        when :remove_column, :remove_columns, :remove_timestamps, :remove_reference, :remove_belongs_to
          check_columns_removal(command, *args, **options)
        else
          if respond_to?(command, true)
            send(command, *args, **options, &block)
          else
            # assume it is safe
            true
          end
        end
      end

      def create_table(_table_name, **options, &block)
        raise_error :create_table if options[:force]

        # Probably, it would be good idea to also check for foreign keys
        # with short integer types, and for mismatched primary key vs foreign key types.
        # But I think this check is enough for now.
        raise_error :short_primary_key_type if short_primary_key_type?(options)

        if block
          collect_foreign_keys(&block)
          check_for_hash_indexes(&block) if postgresql_version < Gem::Version.new("10")
        end
      end

      def create_join_table(_table1, _table2, **options, &block)
        raise_error :create_table if options[:force]
        raise_error :short_primary_key_type if short_primary_key_type?(options)

        if block
          collect_foreign_keys(&block)
          check_for_hash_indexes(&block) if postgresql_version < Gem::Version.new("10")
        end
      end

      def rename_table(table_name, new_name, **)
        raise_error :rename_table,
          table_name: table_name,
          new_name: new_name
      end

      def add_column(table_name, column_name, type, **options)
        volatile_default = false
        if !options[:default].nil? &&
           (postgresql_version < Gem::Version.new("11") || (volatile_default = Utils.volatile_default?(connection, type, options[:default])))

          raise_error :add_column_with_default,
            code: command_str(:add_column_with_default, table_name, column_name, type, options),
            not_null: options[:null] == false,
            volatile_default: volatile_default
        end

        if type.to_s == "json"
          raise_error :add_column_json,
            code: command_str(:add_column, table_name, column_name, :jsonb, options)
        end
      end

      def rename_column(table_name, column_name, new_column, **)
        raise_error :rename_column,
          table_name: table_name,
          column_name: column_name,
          new_column: new_column,
          model: table_name.to_s.classify,
          partial_writes: Utils.ar_partial_writes?,
          partial_writes_setting: Utils.ar_partial_writes_setting
      end

      def change_column(table_name, column_name, type, **options)
        type = type.to_sym

        existing_column = connection.columns(table_name).find { |c| c.name == column_name.to_s }
        if existing_column
          existing_type = existing_column.type.to_sym

          safe =
            case type
            when :string
              # safe to increase limit or remove it
              # not safe to decrease limit or add a limit
              case existing_type
              when :string
                !options[:limit] || (existing_column.limit && options[:limit] >= existing_column.limit)
              when :text
                !options[:limit]
              end
            when :text
              # safe to change varchar to text (and text to text)
              [:string, :text].include?(existing_type)
            when :numeric, :decimal
              # numeric and decimal are equivalent and can be used interchangably
              [:numeric, :decimal].include?(existing_type) &&
              (
                (
                  # unconstrained
                  !options[:precision] && !options[:scale]
                ) || (
                  # increased precision, same scale
                  options[:precision] && existing_column.precision &&
                  options[:precision] >= existing_column.precision &&
                  options[:scale] == existing_column.scale
                )
              )
            when :datetime, :timestamp, :timestamptz
              [:timestamp, :timestamptz].include?(existing_type) &&
              postgresql_version >= Gem::Version.new("12") &&
              connection.select_value("SHOW timezone") == "UTC"
            else
              type == existing_type &&
              options[:limit] == existing_column.limit &&
              options[:precision] == existing_column.precision &&
              options[:scale] == existing_column.scale
            end

          # unsafe to set NOT NULL for safe types
          if safe && existing_column.null && options[:null] == false
            raise_error :change_column_with_not_null
          end

          if !safe
            raise_error :change_column,
              initialize_change_code: command_str(:initialize_column_type_change, table_name, column_name, type, **options),
              backfill_code: command_str(:backfill_column_for_type_change, table_name, column_name, **options),
              finalize_code: command_str(:finalize_column_type_change, table_name, column_name),
              cleanup_code: command_str(:cleanup_change_column_type_concurrently, table_name, column_name),
              cleanup_down_code: command_str(:initialize_column_type_change, table_name, column_name, existing_type)
          end
        end
      end

      def change_column_null(table_name, column_name, allow_null, default = nil, **)
        if !allow_null
          safe = false
          # In PostgreSQL 12+ you can add a check constraint to the table
          # and then "promote" it to NOT NULL for the column.
          if postgresql_version >= Gem::Version.new("12")
            safe = check_constraints(table_name).any? do |c|
              c["def"] == "CHECK ((#{column_name} IS NOT NULL))" ||
                c["def"] == "CHECK ((#{connection.quote_column_name(column_name)} IS NOT NULL))"
            end
          end

          if !safe
            constraint_name = "#{table_name}_#{column_name}_null"
            vars = {
              add_constraint_code: command_str(:add_not_null_constraint, table_name, column_name, name: constraint_name, validate: false),
              backfill_code: nil,
              validate_constraint_code: command_str(:validate_not_null_constraint, table_name, column_name, name: constraint_name),
              remove_constraint_code: nil,
            }

            if !default.nil?
              vars[:backfill_code] = command_str(:update_column_in_batches, table_name, column_name, default)
            end

            if postgresql_version >= Gem::Version.new("12")
              vars[:remove_constraint_code] = command_str(:remove_check_constraint, table_name, name: constraint_name)
              vars[:change_column_null_code] = command_str(:change_column_null, table_name, column_name, true)
            end

            raise_error :change_column_null, **vars
          end
        end
      end

      def check_columns_removal(command, *args, **options)
        case command
        when :remove_column
          table_name, column_name = args
          columns = [column_name]
        when :remove_columns
          table_name, *columns = args
        when :remove_timestamps
          table_name = args[0]
          columns = [:created_at, :updated_at]
        else
          table_name, reference = args
          columns = [:"#{reference}_id"]
          columns << :"#{reference}_type" if options[:polymorphic]
        end

        indexes = connection.indexes(table_name).select do |index|
          (index.columns & columns.map(&:to_s)).any?
        end

        raise_error :remove_column,
          model: table_name.to_s.classify,
          columns: columns.inspect,
          command: command_str(command, *args),
          table_name: table_name.inspect,
          indexes: indexes.map { |i| i.name.to_sym.inspect }
      end

      def add_timestamps(table_name, **options)
        volatile_default = false
        if !options[:default].nil? &&
           (postgresql_version < Gem::Version.new("11") || (volatile_default = Utils.volatile_default?(connection, :datetime, options[:default])))

          raise_error :add_timestamps_with_default,
            code: [command_str(:add_column_with_default, table_name, :created_at, :datetime, options),
                   command_str(:add_column_with_default, table_name, :updated_at, :datetime, options)].join("\n    "),
            not_null: options[:null] == false,
            volatile_default: volatile_default
        end
      end

      def add_reference(table_name, ref_name, **options)
        # Always added by default in 5.0+
        index = options.fetch(:index) { Utils.ar_version >= 5.0 }

        if index.is_a?(Hash) && index[:using].to_s == "hash" && postgresql_version < Gem::Version.new("10")
          raise_error :add_hash_index
        end

        concurrently_set = index.is_a?(Hash) && index[:algorithm] == :concurrently
        bad_index = index && !concurrently_set

        foreign_key = options.fetch(:foreign_key, false)

        if foreign_key
          foreign_table_name = Utils.foreign_table_name(ref_name, options)
          @foreign_key_tables << foreign_table_name.to_s
        end

        validate_foreign_key = !foreign_key.is_a?(Hash) ||
                               (!foreign_key.key?(:validate) || foreign_key[:validate] == true)
        bad_foreign_key = foreign_key && validate_foreign_key

        if bad_index || bad_foreign_key
          raise_error :add_reference,
            code: command_str(:add_reference_concurrently, table_name, ref_name, **options),
            bad_index: bad_index,
            bad_foreign_key: bad_foreign_key
        end
      end
      alias add_belongs_to add_reference

      def add_index(table_name, column_name, **options)
        if options[:using].to_s == "hash" && postgresql_version < Gem::Version.new("10")
          raise_error :add_hash_index
        elsif options[:algorithm] != :concurrently
          raise_error :add_index,
            command: command_str(:add_index, table_name, column_name, **options.merge(algorithm: :concurrently))
        end
      end

      def remove_index(table_name, column_name = nil, **options)
        options[:column] ||= column_name

        if options[:algorithm] != :concurrently
          raise_error :remove_index,
            command: command_str(:remove_index, table_name, **options.merge(algorithm: :concurrently))
        end
      end

      def add_foreign_key(from_table, to_table, **options)
        validate = options.fetch(:validate, true)

        if validate
          raise_error :add_foreign_key,
            add_code: command_str(:add_foreign_key, from_table, to_table, **options.merge(validate: false)),
            validate_code: command_str(:validate_foreign_key, from_table, to_table)
        end

        @foreign_key_tables << to_table.to_s
      end

      def validate_foreign_key(*)
        if crud_blocked?
          raise_error :validate_foreign_key
        end
      end

      def add_check_constraint(table_name, expression, **options)
        if options[:validate] != false
          name = options[:name] || check_constraint_name(table_name, expression)

          raise_error :add_check_constraint,
            add_code: command_str(:add_check_constraint, table_name, expression, **options.merge(validate: false)),
            validate_code: command_str(:validate_check_constraint, table_name, name: name)
        end
      end

      def validate_check_constraint(*)
        if crud_blocked?
          raise_error :validate_constraint
        end
      end

      def execute(*)
        raise_error :execute, header: "Possibly dangerous operation"
      end

      def short_primary_key_type?(options)
        pk_type =
          case options[:id]
          when false
            nil
          when Hash
            options[:id][:type]
          when nil
            # default type is used
            connection.native_database_types[:primary_key].split.first
          else
            options[:id]
          end

        pk_type && !["bigserial", "bigint", "uuid"].include?(pk_type.to_s)
      end

      def collect_foreign_keys(&block)
        collector = ForeignKeysCollector.new
        collector.collect(&block)
        @foreign_key_tables |= collector.referenced_tables
      end

      def check_for_hash_indexes(&block)
        indexes = collect_indexes(&block)
        if indexes.any? { |index| index.using == "hash" }
          raise_error :add_hash_index
        end
      end

      def collect_indexes(&block)
        collector = IndexesCollector.new
        collector.collect(&block)
        collector.indexes
      end

      def postgresql_version
        version =
          if Utils.developer_env? && (target_version = OnlineMigrations.config.target_version)
            target_version.to_s
          else
            database_version = connection.database_version
            patch = database_version % 100
            database_version /= 100
            minor = database_version % 100
            database_version /= 100
            major = database_version
            "#{major}.#{minor}.#{patch}"
          end

        Gem::Version.new(version)
      end

      def connection
        @migration.connection
      end

      def raise_error(message_key, **vars)
        template = OnlineMigrations.config.error_messages.fetch(message_key)

        vars[:migration_name] = @migration.name
        vars[:migration_parent] = Utils.migration_parent_string
        vars[:model_parent] = Utils.model_parent_string

        message = ERB.new(template, trim_mode: "<>").result_with_hash(vars)

        @migration.stop!(message)
      end

      def command_str(command, *args)
        arg_list = args[0..-2].map(&:inspect)

        last_arg = args.last
        if last_arg.is_a?(Hash)
          if last_arg.any?
            arg_list << last_arg.map do |k, v|
              case v
              when Hash
                # pretty index: { algorithm: :concurrently }
                "#{k}: { #{v.map { |k2, v2| "#{k2}: #{v2.inspect}" }.join(', ')} }"
              when Array, Numeric, String, Symbol, TrueClass, FalseClass
                "#{k}: #{v.inspect}"
              else
                "<paste value here>"
              end
            end.join(", ")
          end
        else
          arg_list << last_arg.inspect
        end

        "#{command} #{arg_list.join(', ')}"
      end

      def crud_blocked?
        locks_query = <<~SQL
          SELECT relation::regclass::text
          FROM pg_locks
          WHERE mode IN ('ShareLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')
            AND pid = pg_backend_pid()
        SQL

        connection.select_values(locks_query).any?
      end

      def check_constraint_name(table_name, expression)
        identifier = "#{table_name}_#{expression}_chk"
        hashed_identifier = OpenSSL::Digest::SHA256.hexdigest(identifier).first(10)

        "chk_rails_#{hashed_identifier}"
      end

      def check_constraints(table_name)
        constraints_query = <<~SQL
          SELECT pg_get_constraintdef(oid) AS def
          FROM pg_constraint
          WHERE contype = 'c'
            AND convalidated
            AND conrelid = #{connection.quote(table_name)}::regclass
        SQL

        connection.select_all(constraints_query).to_a
      end
  end
end