module Gemstash
  module GemSource
    class VersionCaching

      def serve_versions
        content_type "application/octet-stream"
        Marshal.dump(versions.fetch)
      end

      def serve_versions_json
        content_type "application/json;charset=UTF-8"
        versions.fetch.to_json
      end
    end
  end
end
