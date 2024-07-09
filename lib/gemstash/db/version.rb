# frozen_string_literal: true

require "gemstash"

module Gemstash
  module DB
    # Sequel model for versions table.
    class Version < Sequel::Model
      many_to_one :rubygem

      def deindex
        info = Gemstash::CompactIndexBuilder::Info.new(nil, rubygem.name).tap(&:build_result).result
        prefix = number.dup
        prefix << "-#{platform}" if platform != "ruby"
        info.gsub!(/^#{Regexp.escape(prefix)} .*?\n/, "")
        update(indexed: false, yanked_at: Time.now.utc, yanked_info_checksum: Digest::MD5.hexdigest(info))
      end

      def reindex
        update(indexed: true)
      end

      def self.slug(params)
        version = params[:version]
        platform = params[:platform]

        if platform.to_s.empty?
          version
        else
          "#{version}-#{platform}"
        end
      end

      def self.for_spec_collection(prerelease: false, latest: false)
        versions = where(indexed: true, prerelease: prerelease).association_join(:rubygem).
                   order { [rubygem[:name], platform.desc] }
        versions = select_latest(versions) if latest
        order_for_spec_collection(versions)
      end

      def self.select_latest(versions)
        versions.
          all.
          group_by {|version| [version.rubygem_id, version.platform] }.
          values.
          map {|gem_versions| gem_versions.max_by {|version| Gem::Version.new(version.number) } }
      end

      def self.order_for_spec_collection(versions)
        versions.to_enum.group_by(&:rubygem_id).flat_map do |_, gem_versions|
          versions = Hash.new {|h, k| h[k] = Gem::Version.new(k) }
          numbers = gem_versions.map {|version| versions[version.number] }
          numbers.sort!
          gem_versions.sort_by do |version|
            [-numbers.index(version.number), version.platform]
          end.reverse
        end
      end

      def self.find_by_spec(gem_id, spec)
        self[rubygem_id: gem_id,
             number: spec.version.to_s,
             platform: spec.platform.to_s]
      end

      def self.find_by_full_name(full_name)
        result = self[full_name: full_name]
        return result if result

        # Try again with the default platform, in case it is implied
        self[full_name: "#{full_name}-ruby"]
      end

      def self.insert_by_spec(gem_id, spec, sha256:)
        gem_name = Gemstash::DB::Rubygem[gem_id].name
        info = Gemstash::CompactIndexBuilder::Info.new(nil, gem_name).tap(&:build_result).result
        info << CompactIndex::GemVersion.new(
          spec.version.to_s,
          spec.platform.to_s,
          sha256,
          nil, # info_checksum
          spec.runtime_dependencies.map do |dep|
            requirements = dep.requirement.requirements
            requirements = requirements.map {|r| "#{r.first} #{r.last}" }
            requirements = requirements.join(", ")
            CompactIndex::Dependency.new(dep.name, requirements)
          end,
          spec.required_ruby_version&.to_s,
          spec.required_rubygems_version&.to_s
        ).to_line << "\n"
        new(rubygem_id: gem_id,
            number: spec.version.to_s,
            platform: spec.platform.to_s,
            full_name: "#{gem_name}-#{spec.version}-#{spec.platform}",
            storage_id: spec.full_name,
            indexed: true,
            sha256: sha256,
            info_checksum: Digest::MD5.hexdigest(info),
            required_ruby_version: spec.required_ruby_version&.to_s,
            required_rubygems_version: spec.required_rubygems_version&.to_s,
            prerelease: spec.version.prerelease?).tap(&:save).id
      end
    end
  end
end
