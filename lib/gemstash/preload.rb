module Gemstash
  module Preload
    class GemPuller
    end

    class GemName
      def initialize(gem)
        (@name, @version, _) = gem
      end

      def to_s
        "#{@name}-#{@version.to_s}"
      end
    end

    class GemSpecs
      include Enumerable

      def fetch
        con = Connection.new
        puts "Downloading latest specs..."
        req = con.get "/latest_specs.4.8.gz"
        puts "Inflating specs..."
        reader = Zlib::GzipReader.new(StringIO.new(req.body.to_s))
        @specs = Marshal.load(reader.read)
        self
      end

      def each(&block)
        @specs.each do |gem|
          yield GemName.new(gem)
        end
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
