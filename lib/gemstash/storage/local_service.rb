# frozen_string_literal: true

require "fileutils"

module Gemstash
  class Storage
    class LocalService < BaseService # :nodoc:
      include Gemstash::Env::Helper

      def exist?(filename)
        File.exist?(filename)
      end

      def store(filename, content)
        folder = File.dirname(filename)
        FileUtils.mkpath(folder) unless Dir.exist?(folder)
        save_file(filename) { content }
      end

      def read(filename)
        File.open(filename, "rb", &:read)
      end

      def delete(filename)
        File.delete(filename)
      end

    private

      def save_file(filename)
        content = yield
        gemstash_env.atomic_write(filename) {|f| f.write(content) }
      end
    end
  end
end
