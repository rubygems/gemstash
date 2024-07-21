# frozen_string_literal: true

require "active_support/core_ext/string/filters"
require "compact_index"
require "gemstash"
require "stringio"
require "zlib"

module Gemstash
  # Comment
  class CompactIndexBuilder
    include Gemstash::Env::Helper
    attr_reader :result

    def self.serve(app, ...)
      app.content_type "text/plain; charset=utf-8"
      body = new(app.auth, ...).serve
      app.etag Digest::MD5.hexdigest(body)
      sha256 = Digest::SHA256.base64digest(body)
      app.headers "Accept-Ranges" => "bytes", "Digest" => "sha-256=#{sha256}", "Repr-Digest" => "sha-256=:#{sha256}:",
                  "Content-Length" => body.bytesize.to_s
      body
    end

    def self.invalidate_stored(name)
      storage = Gemstash::Storage.for("private").for("compact_index")
      storage.resource("names").delete(:names)
      storage.resource("versions").delete(:versions)
      storage.resource("info/#{name}").delete(:info)
    end

    def initialize(auth)
      @auth = auth
    end

    def serve
      check_auth if gemstash_env.config[:protected_fetch]
      fetch_from_storage
      return result if result

      build_result
      store_result
      result
    end

  private

    def storage
      @storage ||= Gemstash::Storage.for("private").for("compact_index")
    end

    def fetch_from_storage
      resource = fetch_resource
      return unless resource.exist?(key)

      @result = resource.load(key).content(key)
    rescue StandardError
      # On the off-chance of a race condition between specs.exist? and specs.load
      @result = nil
    end

    def store_result
      fetch_resource.save(key => @result)
    end

    def check_auth
      @auth.check("fetch")
    end

    # Comment
    class Versions < CompactIndexBuilder
      def fetch_resource
        storage.resource("versions")
      end

      def build_result(force_rebuild: false)
        resource = fetch_resource
        base = !force_rebuild && resource.exist?("versions.list") && resource.content("versions.list")
        Tempfile.create("versions.list") do |file|
          versions_file = CompactIndex::VersionsFile.new(file.path)
          if base
            file.write(base)
            file.close
            @result = versions_file.contents(
              compact_index_versions(versions_file.updated_at.to_time)
            )
          else
            ts = Time.now.iso8601
            versions_file.create(
              compact_index_public_versions(ts), ts
            )
            @result = file.read
            resource.save("versions.list" => @result)
          end
        end
      end

    private

      def compact_index_versions(date)
        all_versions = Sequel::Model.db[<<~SQL.squish, date, date].to_a
          SELECT r.name as name, v.created_at as date, v.info_checksum as info_checksum, v.number as number, v.platform as platform
          FROM rubygems AS r, versions AS v
          WHERE v.rubygem_id = r.id AND
                v.created_at > ?

          UNION ALL

          SELECT r.name as name, v.yanked_at as date, v.yanked_info_checksum as info_checksum, '-'||v.number as number, v.platform as platform
          FROM rubygems AS r, versions AS v
          WHERE v.rubygem_id = r.id AND
                v.indexed is false AND
                v.yanked_at > ?

          ORDER BY date, number, platform, name
        SQL

        # not ordered correctly in sqlite for some reason
        all_versions.sort_by! {|v| [v[:date], v[:number], v[:platform], v[:name]] }
        map_gem_versions(all_versions.map {|v| [v[:name], [v]] })
      end

      def compact_index_public_versions(date)
        all_versions = Sequel::Model.db[<<~SQL.squish, date, date].to_a
          SELECT r.name, v.indexed, COALESCE(v.yanked_at, v.created_at) as stamp,
                 COALESCE(v.yanked_info_checksum, v.info_checksum) as info_checksum, v.number, v.platform
          FROM rubygems AS r, versions AS v
            WHERE v.rubygem_id = r.id AND
                  (v.created_at <= ? OR v.yanked_at <= ?)
          ORDER BY name, COALESCE(v.yanked_at, v.created_at), number, platform
        SQL

        versions_by_gem = all_versions.group_by {|row| row[:name] }
        versions_by_gem.each_value do |versions|
          info_checksum = versions.last[:info_checksum]
          versions.select! {|v| v[:indexed] == true }
          # Set all versions' info_checksum to work around https://github.com/bundler/compact_index/pull/20
          versions.each {|v| v[:info_checksum] = info_checksum }
        end

        map_gem_versions(versions_by_gem)
      end

      def map_gem_versions(versions_by_gem)
        versions_by_gem.map do |name, versions|
          CompactIndex::Gem.new(
            name,
            versions.map do |row|
              CompactIndex::GemVersion.new(
                row[:number],
                row[:platform],
                nil, # sha256
                row[:info_checksum],
                nil, # dependencies
                nil, # version.required_ruby_version,
                nil, # version.required_rubygems_version
              )
            end
          )
        end
      end

      def key
        :versions
      end
    end

    # Comment
    class Info < CompactIndexBuilder
      def initialize(auth, name)
        super(auth)
        @name = name
      end

      def fetch_resource
        storage.resource("info/#{@name}")
      end

      def build_result
        @result = CompactIndex.info(requirements_and_dependencies)
      end

    private

      def requirements_and_dependencies
        group_by_columns = "number, platform, sha256, info_checksum, required_ruby_version, required_rubygems_version, versions.created_at"

        dep_req_agg = "string_agg(dependencies.requirements, '@' ORDER BY dependencies.rubygem_name, dependencies.id) as dep_req_agg"

        dep_name_agg = "string_agg(dependencies.rubygem_name, ',' ORDER BY dependencies.rubygem_name) AS dep_name_agg"

        DB::Rubygem.db[<<~SQL.squish, @name].
          SELECT #{group_by_columns}, #{dep_req_agg}, #{dep_name_agg}
          FROM rubygems
            LEFT JOIN versions ON versions.rubygem_id = rubygems.id
            LEFT JOIN dependencies ON dependencies.version_id = versions.id
          WHERE rubygems.name = ? AND versions.indexed = true
          GROUP BY #{group_by_columns}
          ORDER BY versions.created_at, number, platform, dep_name_agg
        SQL
          map do |row|
          reqs = row[:dep_req_agg]&.split("@")
          dep_names = row[:dep_name_agg]&.split(",")

          raise "Dependencies and requirements are not the same size:\n  reqs: #{reqs.inspect}\n  dep_names: #{dep_names.inspect}\n  row: #{row.inspect}" if dep_names&.size != reqs&.size

          deps = []
          if reqs
            dep_names.zip(reqs).each do |name, req|
              deps << CompactIndex::Dependency.new(name, req)
            end
          end

          CompactIndex::GemVersion.new(
            row[:number],
            row[:platform],
            row[:sha256],
            nil, # info_checksum
            deps,
            row[:required_ruby_version],
            row[:required_rubygems_version]
          )
        end
      end

      def key
        :info
      end
    end

    # Comment
    class Names < CompactIndexBuilder
      def fetch_resource
        storage.resource("names")
      end

      def build_result
        names = DB::Rubygem.db[<<~SQL.squish].map {|row| row[:name] }
          SELECT name
          FROM rubygems
          INNER JOIN versions ON versions.rubygem_id = rubygems.id
          WHERE versions.indexed = true
          GROUP BY name
          ORDER BY name
        SQL
        @result = CompactIndex.names(names).encode("UTF-8")
      end

    private

      def key
        :names
      end
    end
  end
end
