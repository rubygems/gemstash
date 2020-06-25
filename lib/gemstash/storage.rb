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

    def initialize(storage_service,folder)
      storage_service ||= gemstash_env.config[:storage_adapter]
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

    def resource(id)
      @storage.resource(id)
    end

    def for(child)
      @storage.for(child)
    end

    def self.for(name, default = false)
      if(default == false)
        new(gemstash_env.base_file).for(name)
      else
        new("local",gemstash_env.).for(name)
      end
    end
  
    def self.metadata
      gemstash_env.storage_service.metadata
    end
  
    def check_credentials 
      @storage.check_credentials
    end
  end
end

