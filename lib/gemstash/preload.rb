require "zlib"
require "thread"
require "forwardable"
require "faraday"

#:nodoc:
module Gemstash
  #:nodoc:
  module Preload
    #:nodoc:
    class GemPreloader
      def initialize(http_client, options, out: STDOUT)
        @http_client = http_client
        @threads = options[:threads] || 20
        @skip = options[:skip] || 0
        @limit = options[:limit]
        @out = out
        @specs = GemSpecs.new(http_client, GemSpecFilename.new(options))
      end

      def preload
        pool = Pool.new(size: @threads)
        each_gem do |gem, index, total|
          @out.write("\r#{index}/#{total}")
          pool.schedule(gem) do |gem_name|
            @http_client.head("gems/#{gem_name}.gem")
          end
        end
        pool.shutdown
      end

    private

      def each_gem
        @specs.fetch
        return if @limit && @limit <= 0
        return if @skip >= @specs.size
        @specs[range].each_with_index do |gem, index|
          yield gem.to_s, index + @skip + 1, @specs.size
        end
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
          @specs = Marshal.load(reader.read).inject([]) do |specs, gem|
            specs << GemName.new(gem)
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

    #:nodoc:
    class Pool
      def initialize(size: 20)
        @size = size
        @jobs = SizedQueue.new(size * 2)
        @pool = (0..@size).map do
          Thread.new do
            catch(:exit) do
              loop do
                job, args = @jobs.pop
                job.call(*args)
              end
            end
          end
        end
      end

      def schedule(*args, &block)
        @jobs << [block, args]
      end

      def shutdown
        @size.times do
          schedule { throw :exit }
        end
        Thread.pass until @jobs.empty?
      end
    end
  end
end
