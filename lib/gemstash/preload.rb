require "zlib"
require "thread"
require "forwardable"

module Gemstash
  module Preload
    class GemPreloader
      def initialize(http_client, latest = false, threads = 20)
        @http_client = http_client
        specs = GemSpecs.new(http_client, latest)
        specs.fetch
        puts "Fetched #{specs.count} specs"
      end
    end

    class GemSpecs
      include Enumerable

      def initialize(http_client, latest = false)
        @http_client = http_client
        @specs_file = "/specs.4.8.gz" unless latest
        @specs_file ||= "/latest_specs.4.8.gz"
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

    class GemName
      def initialize(gem)
        (@name, @version, _) = gem
      end

      def to_s
        "#{@name}-#{@version.to_s}"
      end
    end

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
      end
    end
  end
end
