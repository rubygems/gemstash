require "gemstash"
require "digest"
require "fileutils"
require "yaml"
require "aws-sdk-s3"
require "pathname"

module Gemstash
  class S3
    extend Gemstash::Env::Helper
    include Gemstash::Env::Helper
    attr_reader :folder, :client, :bucket

    VERSION = 1
    class VersionTooNew < StandardError
      def initialize(folder, version)
        super("Gemstash storage version #{Gemstash::S3::VERSION} does " \
               "not support version #{version} found at #{folder}")
      end
    end

    def initialize(folder, root: true)
      @folder = folder
      check_storage_version if root
      @client = Aws::S3::Client.new(
          access_key_id: gemstash_env.config[:aws_access_key_id],
          secret_access_key: gemstash_env.config[:aws_secret_access_key],
          region: gemstash_env.config[:region]
      )
      @bucket_name = gemstash_env.config[:bucket_name]
      @object_name = @folder
    end

    def check_credentials?
      @client.get_bucket_location({bucket: @bucket_name}).location_constraint == gemstash_env.config[:region]
    end
    def resource(id)
      S3Resource.new(@folder,id,@client,@bucket_name)
    end

    def for(child)
      S3.new(File.join(@folder, child),root: false)
    end

    def self.for(name)
      new(File.join(gemstash_env.config[:s3_path],name))
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
    def initialize(folder,name,client,bucket_name)
      @folder = folder
      @name = name
      safe_name = sanitize(@name)
      digest = Digest::MD5.hexdigest(@name)
      child_folder = "#{safe_name}-#{digest}"
      @folder = File.join(@folder, child_folder)
      @client = client
      @S3resource = Aws::S3::Resource.new(client: @client).bucket(bucket_name)
      @properties = nil
    end

    def save(content, properties = nil)
      content.each do |key, value|
        save_content(key, value)
      end
      update_properties(properties)
      self
    end

    def exist?(key = nil)
      if key
        @S3resource.object(properties_filename).exists? && @S3resource.object(content_filename(key)).exists?
      else
        @S3resource.object(properties_filename).exists? && content?
      end
    end

    def content(key)
      @content ||= {}
      load(key) unless @content.include?(key)
      @content[key]
    end

    def properties
      load_properties
      @properties || {}
    end

    def update_properties(props)
      load_properties(true)

      deep_merge = proc do |_, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          old_value.merge(new_value, &deep_merge)
        else
          new_value
        end
      end

      props = properties.merge(props || {}, &deep_merge)
      save_properties(properties.merge(props || {}))
      self
    end

    def property?(*keys)
      keys.inject(node: properties, result: true) do |memo, key|
        if memo[:result]
          memo[:result] = memo[:node].is_a?(Hash) && memo[:node].include?(key)
          memo[:node] = memo[:node][key] if memo[:result]
        end

        memo
      end[:result]
    end

    def delete(key)
      return self unless exist?(key)

      begin
        @S3resource.object(content_filename(key)).delete
      rescue Aws::S3::Errors::ServiceError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to delete stored content at #{content_filename(key)}", e, level: :warn
      end

      begin
        @S3resource.object(properties_filename).delete unless content?
      rescue Aws::S3::Errors::ServiceError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to delete stored properties at #{properties_filename}", e, level: :warn
      end

      self
      ensure
        reset
      end


    private
    def content?
      return false unless @S3resource.object(@folder).exists?

      entries = @S3resource.objects(prefix: (@folder)).collect().reject { |object| object.content_length == 0 || object.key == "properties.yaml" }
      !entries.empty?
    end

    def load_properties(force = false)
      return if @properties && !force
      return unless @S3resource.object(properties_filename).exists?
      begin
        properties_file = @S3resource.object(properties_filename).get.body
      rescue  Aws::S3::Errors::ServiceError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to fetch content at #{properties_filename}", e, level: :warn
      end
      @properties = YAML.load(properties_file) || {}
      check_resource_version
    end

    def save_properties(props)
      props ||= {}
      props = { gemstash_resource_version: Gemstash::S3Resource::VERSION }.merge(props)
      begin
        store(properties_filename, props.to_yaml)
      rescue Aws::S3::Errors::ServiceError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to update properties at #{properties_filename}", e, level: :warn
      else
        @properties = props
      end
    end

    def load(key)
      raise "Resource #{@name} has no #{key.inspect} content to load" unless exist?(key)
      load_properties # Ensures storage version is checked
      @content ||= {}
      begin
        @content[key] = read_file(content_filename(key))
      rescue Aws::S3::Errors::ServiceError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to load content at #{content_filename(key)}", e, level: :warn
      end
    end

    def check_resource_version
      version = @properties[:gemstash_resource_version]
      return if version <= Gemstash::S3Resource::VERSION

      reset
      raise Gemstash::S3Resource::VersionTooNew.new(name, folder, version)
    end

    def sanitize(name)
      name.gsub(/[^a-zA-Z0-9_]/, "_")
    end

    def save_content(key,content)
      begin
        store(content_filename(key), content)
      rescue  Aws::S3::Errors::ServiceError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to store content at #{content_filename(key)}", e, level: :warn
      else
        @content ||= {}
        @content[key] = content
      end
    end

    def store(filename,content)
      save_file(filename) { content }
    end

    def content_filename(key)
      name = sanitize(key.to_s)
      raise "Invalid content key #{key.inspect}" if name.empty?

      File.join(@folder, name)
    end

    def read_file(filename)
      @S3resource.object(filename).get().body.read.b
    end

    def properties_filename
      File.join(@folder, "properties.yaml")
    end

    def save_file(filename)
      content = yield
      @S3resource.object(filename).put(body: content, content_encoding: "ASCII")
    end

    def reset
      @content = nil
      @properties = nil
    end

  end
end
