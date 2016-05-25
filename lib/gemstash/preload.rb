require "zlib"
require "forwardable"
require "parallel"

#:nodoc:
module Gemstash
  #:nodoc:
  module Preload
    #:nodoc:
    class GemPreloader
      def initialize(http_client, options = {})
        @http_client = http_client
        @threads = options[:threads] || 20
        @skip = options[:skip] || 0
        @limit = options[:limit]
        @specs = GemSpecs.new(http_client, GemSpecFilename.new(options))
      end

      def preload
        Parallel.map(specs, in_threads: @threads, progress: "downloading gems") do |gem_name|
          @http_client.head("gems/#{gem_name}.gem")
        end
      end

    private

      def specs
        @specs.fetch
        return if @limit && @limit <= 0
        return if @skip >= @specs.size
        @specs[range]
      end

      def range
        limit = (@limit || @specs.size) + @skip
        (@skip...limit)
      end
    end

    #:nodoc:
    class GemSpecFilename
      def initialize(options = {})
        @latest = options[:latest]
        @prerelease = options[:prerelease]
        raise "It makes no sense to ask for latest and prerelease, pick only one" if @prerelease && @latest
      end

      def to_s
        prefix = "latest_" if @latest
        prefix = "prerelease_" if @prerelease
        "#{prefix}specs.4.8.gz"
      end
    end

    #:nodoc:
    class GemSpecs
      extend Forwardable

      def_delegators :@specs, :each, :size, :each_with_index, :[], :first, :last, :empty?

      def initialize(http_client, filename = GemSpecFilename.new)
        @http_client = http_client
        @specs_file = filename.to_s
      end

      def fetch
        begin
          reader = Zlib::GzipReader.new(StringIO.new(@http_client.get(@specs_file)))
          @specs = Marshal.load(reader.read).inject([]) do |specs, gem_spec|
            specs << GemName.new(gem_spec)
          end
        ensure
          reader.close if reader
        end
        self
      end
    end

    #:nodoc:
    class GemName
      def initialize(gem)
        (@name, @version, _ignored) = gem
      end

      def to_s
        "#{@name}-#{@version}"
      end
    end
  end
end
