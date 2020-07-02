# frozen_string_literal: true

require "gemstash"
require "digest"
require "fileutils"
require "pathname"
require "yaml"

module Gemstash

  class Storage
    include Gemstash::Env::Helper

    class InvalidStorage < StandardError
      def initialize(storage_service)
        super("Gemstash storage doesn't support #{storage_service} service")
      end
    end

    def initialize(storage_service = gemstash_env.config[:storage_adapter], folder)
      @storage = begin
        case storage_service
           when "local"
             Gemstash::LocalStorage.new(folder)
           when "s3"
             Gemstash::S3.new(folder)
           else
             raise Gemstash::Storage::InvalidStorage.new(storage_service)
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
        new(storage_service,gemstash_env.base_file(name))
      when "s3"
        new(storage_service,File.join(gemstash_env.config[:s3_path],name))
      else
        raise Gemstash::Storage::InvalidStorage.new(storage_service)
      end
    end

    def self.metadata
      gemstash_env.storage_service.metadata
    end

    def check_credentials
      @storage.check_credentials
    end

    def resource(id)
      @storage.resource(id)
    end
  end
end

