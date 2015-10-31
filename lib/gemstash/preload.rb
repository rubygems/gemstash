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
      def initialize(http_client, out: STDOUT, latest: false)
        @http_client = http_client
        @threads = 20
        @skip = 0
        @out = out
        @specs = GemSpecs.new(http_client, latest: latest)
      end

      def threads(size)
        @threads = size
        self
      end

      def limit(size)
        @limit = size
        self
      end

      def skip(size)
        @skip = size
        self
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
        gem_specs = @specs.fetch.to_a
        return if !@limit.nil? && @limit <= 0
        return if @skip >= gem_specs.size
        gem_specs[range_for(gem_specs)].each_with_index do |gem, index|
          yield gem.to_s, index + @skip + 1, gem_specs.size
        end
      end

      def range_for(gem_specs)
        limit = (@limit || gem_specs.size) + @skip - 1
        (@skip..limit)
      end
    end

    #:nodoc:
    class GemSpecs
      include Enumerable

      def initialize(http_client, latest: false)
        @http_client = http_client
        @specs_file = "specs.4.8.gz" unless latest
        @specs_file ||= "latest_specs.4.8.gz"
      end

      def fetch
        reader = Zlib::GzipReader.new(
          StringIO.new(@http_client.get(@specs_file)))
        @specs = Marshal.load(reader.read)
        self
      end

      def each(&block)
        @specs.each do |gem|
          yield GemName.new(gem)
        end
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
