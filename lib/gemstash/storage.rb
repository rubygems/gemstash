# frozen_string_literal: true

require "gemstash"
require "digest"
require "fileutils"
require "pathname"
require "yaml"

module Gemstash
  # Adapter class to abstract different storage backend.
  class Storage
    extend Gemstash::Env::Helper
    include Gemstash::Env::Helper

    # Exception for invalid backend service.
    class InvalidStorage < StandardError
      def initialize(storage_service)
        super("Gemstash storage doesn't support #{storage_service} service")
      end
    end

    def initialize(folder, storage_service = gemstash_env.config[:storage_adapter])
      @storage = begin
        case storage_service
        when "local"
          Gemstash::LocalStorage.new(folder)
        when "s3"
          Gemstash::S3.new(folder)
        else
          raise Gemstash::Storage::InvalidStorage, storage_service
        end
      end
    end

    def for(child)
      @storage.for(child)
    end

    def self.for(name)
      storage_service = gemstash_env.config[:storage_adapter]
      case storage_service
      when "local"
        new(gemstash_env.base_file(name), storage_service)
      when "s3"
        new(File.join(gemstash_env.config[:s3_path], name), storage_service)
      else
        raise Gemstash::Storage::InvalidStorage, storage_service
      end
    end

    def self.metadata
      storage_service = gemstash_env.config[:storage_adapter]
      case storage_service
      when "local"
        Gemstash::LocalStorage.metadata
      when "s3"
        Gemstash::S3.metadata
      else
        raise Gemstash::Storage::InvalidStorage, storage_service
      end
    end

    def check_credentials
      @storage.check_credentials
    end

    def resource(id)
      @storage.resource(id)
    end
  end
end
