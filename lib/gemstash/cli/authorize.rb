# frozen_string_literal: true

require "gemstash"
require "securerandom"
require "terminal-table"

module Gemstash
  class CLI
    # This implements the command line authorize task to authorize users:
    #  $ gemstash authorize authorized-key
    class Authorize < Gemstash::CLI::Base
      def run
        prepare
        setup_logging

        # Catch invalid option combinations
        raise Gemstash::CLI::Error.new(@cli, "--remove and --list cannot both be used") if @cli.options[:remove] && @cli.options[:list]

        if @cli.options[:remove]
          remove_authorization
        elsif @cli.options[:list]
          list_authorizations
        else
          save_authorization
        end
      end

    private

      def setup_logging
        Gemstash::Logging.setup_logger(gemstash_env.log_file)
      end

      def remove_authorization
        raise Gemstash::CLI::Error.new(@cli, "--name cannot be used with --remove") if @cli.options[:remove] && @cli.options[:name]

        unless @args.empty?
          raise Gemstash::CLI::Error.new(@cli, "To remove individual permissions, you do not need --remove
Instead just authorize with the new set of permissions")
        end
        Gemstash::Authorization.remove(auth_key(allow_generate: false))
      end

      def save_authorization
        raise Gemstash::CLI::Error.new(@cli, "Don't specify permissions to authorize for all") if @args.include?("all")

        @args.each do |arg|
          unless Gemstash::Authorization::VALID_PERMISSIONS.include?(arg)
            valid = Gemstash::Authorization::VALID_PERMISSIONS.join(", ")
            raise Gemstash::CLI::Error.new(@cli, "Invalid permission '#{arg}'\nValid permissions include: #{valid}")
          end
        end

        begin
          name = @cli.options[:name]
          Gemstash::Authorization.authorize(auth_key, permissions, name)
        rescue Sequel::UniqueConstraintViolation => e
          raise unless name && e.message.include?("authorizations.name")

          raise Gemstash::CLI::Error.new(@cli, "Authorization with name '#{name}' already exists")
        end
      end

      def list_authorizations
        raise Gemstash::CLI::Error.new(@cli, "--key and --name cannot both be used with --list") if @cli.options[:name] && @cli.options[:key]

        rows = map_authorizations(@cli.options[:key], @cli.options[:name]) do |authorization|
          [authorization.name, authorization.auth_key, authorization.permissions]
        end

        @cli.say Terminal::Table.new :headings => %w[Name Key Permissions], :rows => rows
      end

      def auth_key(allow_generate: true)
        if @cli.options[:key]
          @cli.options[:key]
        elsif allow_generate
          key = SecureRandom.hex(16)
          key = SecureRandom.hex(16) while Gemstash::Authorization[key]
          @cli.say "Your new key is: #{key}"
          key
        else
          raise Gemstash::CLI::Error.new(@cli, "The --key option is required to remove an authorization key")
        end
      end

      def permissions
        if @args.empty?
          "all"
        else
          @args
        end
      end

      def map_authorizations(key = nil, name = nil, &block)
        return Gemstash::DB::Authorization.map(&block) unless name || key

        authorization = if name
          Gemstash::DB::Authorization[name: name].tap do |authorization|
            raise Gemstash::CLI::Error.new(@cli, "No authorization named '#{name}'") unless authorization
          end
        else
          Gemstash::DB::Authorization[auth_key: key].tap do |authorization|
            raise Gemstash::CLI::Error.new(@cli, "No authorization with key '#{key}'") unless authorization
          end
        end

        [yield(authorization)]
      end
    end
  end
end
