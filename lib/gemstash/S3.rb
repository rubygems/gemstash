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

  end
end
