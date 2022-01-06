# frozen_string_literal: true

module OnlineMigrations
  # @private
  module Utils
    class << self
      def ar_version
        ActiveRecord.version.to_s.to_f
      end

      def say(message)
        message = "[online_migrations] #{message}"
        if (migration = OnlineMigrations.current_migration)
          migration.say(message)
        elsif (logger = ActiveRecord::Base.logger)
          logger.info(message)
        end
      end

      def migration_parent
        if ar_version <= 4.2
          ActiveRecord::Migration
        else
          ActiveRecord::Migration[ar_version]
        end
      end

      def migration_parent_string
        if ar_version <= 4.2
          "ActiveRecord::Migration"
        else
          "ActiveRecord::Migration[#{ar_version}]"
        end
      end
    end
  end
end
