require "gemstash"
require "digest"
require "fileutils"
require "yaml"
require "aws-sdk-s3"
require "pathname"

module Gemstash
  class S3
    extend Gemstash::Env::Helper
    attr_reader :folder, :client, :bucket

    VERSION = 1
    class VersionTooNew < StandardError
      def initialize(folder, version)
        super("Gemstash storage version #{Gemstash::S3::VERSION} does " \
               "not support version #{version} found at #{folder}")
      end
    end

    def initialize(folder, gemstash_env, root: true)
      @folder = folder
      check_storage_version if root
      @gemstash_env = gemstash_env
      @client = Aws::S3::Client.new(
          access_key_id: gemstash_env.config[:access_key_id],
          secret_access_key: gemstash_env.config[:secret_access_key],
          region: gemstash_env.config[:region],
          stub_responses: false
      )
      @object_name = @folder
    end

    def resource(id)
      S3Resource.new(@folder,id,@client)
    end

    def for(child)
      S3.new(File.join(@folder, child), @gemstash_env, root: false)
    end

    def self.for(name)
      new(gemstash_env.base_file(name),gemstash_env)
    end

    def self.metadata
      file = gemstash_env.base_file("metadata.yml")
      unless File.exist?(file)
        gemstash_env.atomic_write(file) do |f|
          f.write({ storage_version: Gemstash::S3::VERSION,
                    gemstash_version: Gemstash::VERSION }.to_yaml)
        end
      end

      YAML.load_file(file)
    end

    private

    def check_storage_version
      version = Gemstash::S3.metadata[:storage_version]
      return if version <= Gemstash::S3::VERSION

      raise Gemstash::S3::VersionTooNew.new(@folder, version)
    end


  end
  class S3Resource
    include Gemstash::Env::Helper
    include Gemstash::Logging
    attr_reader :name, :folder, :client
    VERSION = 1

    class VersionTooNew < StandardError
      def initialize(name, folder, version)
        super("Gemstash resource version #{Gemstash::S3Resource::VERSION} does " \
               "not support version #{version} for resource #{name.inspect} " \
               "found at #{folder}")
      end
    end
    def initialize(folder,name,client)
      @folder = folder
      @name = name
      safe_name = sanitize(@name)
      digest = Digest::MD5.hexdigest(@name)
      child_folder = "#{safe_name}-#{digest}"
      @folder = File.join(@folder, child_folder)
      @client = client
      @S3resource = Aws::S3::Resource.new(client: @client).bucket(gemstash_env.config[:bucket_name])
      @properties = nil
    end
  end
end
