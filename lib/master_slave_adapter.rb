require 'active_record'

module ActiveRecord
  class Base
    class << self
      def with_consistency(clock, &blk)
        if connection.respond_to? :with_consistency
          connection.with_consistency(clock, &blk)
        else
          yield
        end
      end

      def with_master(&blk)
        if connection.respond_to? :with_master
          connection.with_master(&blk)
        else
          yield
        end
      end

      def with_slave(&blk)
        if connection.respond_to? :with_slave
          connection.with_slave(&blk)
        else
          yield
        end
      end

      def master_slave_connection(config)
        config = massage(config)
        load_adapter(config.fetch(:connection_adapter))
        ConnectionAdapters::MasterSlaveAdapter.new(config, logger)
      end

    private

      def massage(config)
        config = config.symbolize_keys
        skip = [ :adapter, :connection_adapter, :master, :slaves ]
        defaults = config.reject { |k,_| skip.include?(k) }
                         .merge(:adapter => config.fetch(:connection_adapter))
        ([config.fetch(:master)] + config.fetch(:slaves, [])).map do |cfg|
          cfg.symbolize_keys!.reverse_merge!(defaults)
        end
        config
      end

      def load_adapter(adapter_name)
        unless self.respond_to?("#{adapter_name}_connection")
          begin
            require 'rubygems'
            gem "activerecord-#{adapter_name}-adapter"
            require "active_record/connection_adapters/#{adapter_name}_adapter"
          rescue LoadError
            begin
              require "active_record/connection_adapters/#{adapter_name}_adapter"
            rescue LoadError
              raise %Q{Please install the #{adapter_name} adapter:
                       `gem install activerecord-#{adapter_name}-adapter` (#{$!})"}
            end
          end
        end
      end
    end
  end

  module ConnectionAdapters

    class AbstractAdapter
      alias_method :orig_log_info, :log_info
      def log_info(sql, name, ms)
        connection_name =
          [ @config[:name], @config[:host], @config[:port] ].compact.join(":")
        orig_log_info sql, "[#{connection_name}] #{name || 'SQL'}", ms
      end
    end

    class MasterSlaveAdapter < AbstractAdapter

      class Clock
        include Comparable
        attr_reader :file, :position

        def initialize(file, position)
          raise ArgumentError, "file and postion may not be nil" if file.nil? || position.nil?
          @file, @position = file, position.to_i
        end

        def <=>(other)
          @file == other.file ? @position <=> other.position : @file <=> other.file
        end

        def to_s
          [ @file, @position ].join('@')
        end

        def self.zero
          @zero ||= Clock.new('', 0)
        end
      end

      checkout :active?

      def initialize(config, logger)
        super(nil, logger)

        @connections = {}
        @connections[:master] = connect(config.fetch(:master), :master)
        @connections[:slaves] = config.fetch(:slaves).map { |cfg| connect(cfg, :slave) }

        @disable_connection_test = config.delete(:disable_connection_test) == 'true'

        self.current_connection = slave_connection!
      end

      # MASTER SLAVE ADAPTER INTERFACE ========================================

      def with_master
        with(self.master_connection, :master) { yield }
      end

      def with_slave
        with(self.slave_connection!, :slave) { yield }
      end

      def with_consistency(clock)
        raise ArgumentError, "consistency cannot be nil" if clock.nil?
        # try random slave, else fall back to master
        slave = slave_connection!
        conn =
          if !open_transaction? && slave_clock(slave) >= clock
            [ slave, :slave ]
          else
            [ master_connection, :master ]
          end

        with(*conn) { yield }

        self.current_clock || clock
      end


      # backwards compatibility
      class << self
        def with_master(&blk)
          ActiveRecord::Base.with_master(&blk)
        end
        def with_slave(&blk)
          ActiveRecord::Base.with_slave(&blk)
        end
        def with_consistency(clock, &blk)
          ActiveRecord::Base.with_consistency(clock, &blk)
        end
        def reset!
          Thread.current[:master_slave_clock] =
            Thread.current[:master_slave_connection] = nil
        end
      end

      # ADAPTER INTERFACE OVERRIDES ===========================================

      def insert(*args)
        on_write { |conn| conn.insert(*args) }
      end

      def update(*args)
        on_write { |conn| conn.update(*args) }
      end

      def delete(*args)
        on_write { |conn| conn.delete(*args) }
      end

      def commit_db_transaction
        on_write { |conn| conn.commit_db_transaction }
      end

      def active?
        return true if @disable_connection_test
        self.connections.map { |c| c.active? }.reduce(true) { |m,s| s ? m : s }
      end

      def reconnect!
        self.connections.each { |c| c.reconnect! }
      end

      def disconnect!
        self.connections.each { |c| c.disconnect! }
      end

      def reset!
        self.connections.each { |c| c.reset! }
      end

      # ADAPTER INTERFACE DELEGATES ===========================================

      # must go to master
      delegate :adapter_name,
               :supports_migrations?,
               :supports_primary_key?,
               :supports_savepoints?,
               :native_database_types,
               :raw_connection,
               :open_transactions,
               :increment_open_transactions,
               :decrement_open_transactions,
               :transaction_joinable=,
               :create_savepoint,
               :rollback_to_savepoint,
               :release_savepoint,
               :current_savepoint_name,
               :begin_db_transaction,
               :rollback_db_transaction,
               :to => :master_connection
      delegate *ActiveRecord::ConnectionAdapters::SchemaStatements.instance_methods,
               :to => :master_connection
      # silly: :tables is commented in SchemaStatements.
      delegate :tables, :to => :master_connection
      # monkey patch from databasecleaner gem
      delegate :truncate_table, :to => :master_connection

      # determine read connection
      delegate :select_all,
               :select_one,
               :select_rows,
               :select_value,
               :select_values,
               :to => :connection_for_read

      def connection_for_read
        open_transaction? ? master_connection : self.current_connection
      end
      private :connection_for_read

      # UTIL ==================================================================

      def master_connection
        @connections[:master]
      end

      # Returns a random slave connection
      # Note: the method is not referentially transparent, hence the bang
      def slave_connection!
        @connections[:slaves].sample
      end

      def connections
        @connections.values.inject([]) { |m,c| m << c }.flatten.compact
      end

      def current_connection
        connection_stack.first
      end

      def current_connection=(conn)
        connection_stack.unshift conn
      end

      def current_clock
        Thread.current[:master_slave_clock]
      end

      def current_clock=(clock)
        Thread.current[:master_slave_clock] = clock
      end

      def master_clock
        conn = master_connection
        if status = conn.uncached { conn.select_one("SHOW MASTER STATUS") }
          Clock.new(status['File'], status['Position'])
        end
      end

      def slave_clock(connection = nil)
        conn ||= slave_connection!
        if status = conn.uncached { conn.select_one("SHOW SLAVE STATUS") }
          Clock.new(status['Relay_Master_Log_File'], status['Exec_Master_Log_Pos'])
        end
      end

    protected

      def on_write
        with(master_connection, :master) do |conn|
          yield(conn).tap do
            unless open_transaction?
              debug "update_clock"
              if mc = master_clock
                self.current_clock = mc unless current_clock.try(:>=, mc)
              end
              # keep using master after write
              self.current_connection = conn
            end
          end
        end
      end

      def with(conn, name)
        self.current_connection = conn
        yield(conn).tap { connection_stack.shift }
      end

    private

      def logger
        @logger # ||= Logger.new(STDOUT)
      end

      def info(msg)
        logger.try(:info, msg)
      end

      def debug(msg)
        logger.debug(msg) if logger && logger.debug?
      end

      def connect(cfg, name)
        adapter_method = "#{cfg.fetch(:adapter)}_connection".to_sym
        ActiveRecord::Base.send(adapter_method, { :name => name }.merge(cfg))
      end

      def open_transaction?
        master_connection.open_transactions > 0
      end

      def connection_stack
        Thread.current[:master_slave_connection] ||= []
      end
    end
  end
end
