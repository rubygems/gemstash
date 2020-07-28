# frozen_string_literal: true

require "gemstash"
require "digest"
require "fileutils"
require "yaml"
require "pathname"
require "google/cloud/storage"

module Gemstash
  # The entry point into the storage engine for storing cached gems, specs, and
  # private gems using Google Cloud Storage service.
  class GoogleCloudStorage
    extend Gemstash::Env::Helper
    include Gemstash::Env::Helper
    attr_reader :folder, :client, :bucket

    STORAGE_VERSION = 1

    # If the storage engine detects the base cache directory was originally
    # initialized with a newer version, this error is thrown.
    class VersionTooNewError < StandardError
      def initialize(folder, version)
        super("Gemstash storage version #{Gemstash::GoogleCloudStorage::STORAGE_VERSION} does " \
               "not support version #{version} found at #{folder}")
      end
    end

    def initialize(folder, root: true)
      @folder = folder
      @client = Google::Cloud::Storage.new(
        credentials: gemstash_env.config[:google_cloud_keyfile]
      )
      @bucket_name = gemstash_env.config[:bucket_name]
    end

    def check_credentials
      @client.bucket(@bucket_name).exists?
    end

    def delete_with_prefix(prefix = @folder)
      @client.bucket(@bucket_name).files(prefix: prefix, &:delete)
    end

    def resource(id)
      GoogleCloudResource.new(@folder, id, @client, @bucket_name)
    end

    def for(child)
      GoogleCloudStorage.new(File.join(@folder, child), root: false)
    end

    def self.for(name)
      new(File.join(gemstash_env.config[:gcloud_path], name))
    end

    def self.metadata
      file = gemstash_env.base_file("metadata.yml")
      unless File.exist?(file)
        gemstash_env.atomic_write(file) do |f|
          f.write({ storage_version: Gemstash::GoogleCloudStorage::STORAGE_VERSION,
                    gemstash_version: Gemstash::VERSION }.to_yaml)
        end
      end

      YAML.load_file(file)
    end

  private

    def check_storage_version
      version = Gemstash::GoogleCloudStorage.metadata[:storage_version]
      return if version <= Gemstash::GoogleCloudStorage::STORAGE_VERSION

      raise Gemstash::GoogleCloudStorage::VersionTooNewError.new(@folder, version)
    end
  end

  # A resource within the storage engine. The resource may have 1 or more files
  # associated with it along with a metadata Hash that is stored in a YAML file.
  class GoogleCloudResource
    include Gemstash::Env::Helper
    include Gemstash::Logging
    attr_reader :name, :folder, :client
    VERSION = 1

    # If the storage engine detects a resource was originally saved from a newer
    # version, this error is thrown.
    class VersionTooNewError < StandardError
      def initialize(name, folder, version)
        super("Gemstash resource version #{Gemstash::GoogleCloudResource::VERSION} does " \
               "not support version #{version} for resource #{name.inspect} " \
               "found at #{folder}")
      end
    end

    def initialize(folder, name, client, bucket_name)
      @folder = folder
      @name = name
      safe_name = sanitize(@name)
      digest = Digest::MD5.hexdigest(@name)
      child_folder = "#{safe_name}-#{digest}"
      @folder = File.join(@folder, child_folder)
      @gcloudresource = client.bucket(bucket_name)
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
        @gcloudresource.file(content_filename(key)).delete
      rescue StandardError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to delete stored content at #{content_filename(key)}", e, level: :warn
      end

      begin
        @gcloudresource.file(properties_filename).delete unless content?
      rescue StandardError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to delete stored properties at #{properties_filename}", e, level: :warn
      end

      self
    ensure
      reset
    end

  private

    def content?
      return false if @gcloudresource.files(prefix: @folder).map(&:name).exists?

      entries = @gcloudresource.files(prefix: @folder).reject {|file| file.content_length == 0 || (file.key.include? "properties.yaml") }
      !entries.empty?
    end

    def load_properties(force = false)
      return if @properties && !force
      return unless @gcloudresource.file(properties_filename).exists?

      begin
        properties_file = @gcloudresource.file(properties_filename).download
      rescue StandardError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to fetch content at #{properties_filename}", e, level: :warn
      end
      @properties = YAML.load(properties_file) || {}
      check_resource_version
    end

    def save_properties(props)
      props ||= {}
      props = { gemstash_resource_version: Gemstash::GoogleCloudResource::VERSION }.merge(props)
      begin
        store(properties_filename, props.to_yaml)
      rescue StandardError => e
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
      rescue StandardError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to load content at #{content_filename(key)}", e, level: :warn
      end
    end

    def check_resource_version
      version = @properties[:gemstash_resource_version]
      return if version <= Gemstash::GoogleCloudResource::VERSION

      reset
      raise Gemstash::GoogleCloudResource::VersionTooNewError.new(name, folder, version)
    end

    def sanitize(name)
      name.gsub(/[^a-zA-Z0-9_]/, "_")
    end

    def save_content(key, content)
      begin
        store(content_filename(key), content)
      rescue StandardError => e
        log_error "An error has occurred while attempting this operation #{e.context.operation_name},
        Failed to store content at #{content_filename(key)}", e, level: :warn
      else
        @content ||= {}
        @content[key] = content
      end
    end

    def store(filename, content)
      save_file(filename) { content }
    end

    def content_filename(key)
      name = sanitize(key.to_s)
      raise "Invalid content key #{key.inspect}" if name.empty?

      File.join(@folder, name)
    end

    def read_file(filename)
      @gcloudresource.file(filename).download.read.b
    end

    def properties_filename
      File.join(@folder, "properties.yaml")
    end

    def save_file(filename)
      content = yield
      @gcloudresource.create_file(StringIO.new(content), filename)
    end

    def reset
      @content = nil
      @properties = nil
    end
  end
end
