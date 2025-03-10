# frozen_string_literal: true

# :nodoc:
module DBHelpers
  def find_rubygem_id(name)
    Gemstash::Env.current.db[:rubygems][:name => name][:id]
  end

  def insert_rubygem(name)
    Gemstash::Env.current.db[:rubygems].insert(
      :name => name,
      :created_at => Sequel::SQL::Constants::CURRENT_TIMESTAMP,
      :updated_at => Sequel::SQL::Constants::CURRENT_TIMESTAMP
    )
  end

  def insert_version(gem_id, number, platform: "ruby", indexed: true, prerelease: false)
    gem_name = Gemstash::Env.current.db[:rubygems][:id => gem_id][:name]

    storage_id = if platform == "ruby"
      "#{gem_name}-#{number}"
    else
      "#{gem_name}-#{number}-#{platform}"
    end

    Gemstash::Env.current.db[:versions].insert(
      :rubygem_id => gem_id,
      :number => number,
      :platform => platform,
      :full_name => "#{gem_name}-#{number}-#{platform}",
      :storage_id => storage_id,
      :indexed => indexed,
      :prerelease => prerelease,
      :sha256 => Digest::SHA256.hexdigest(storage_id),
      :created_at => Sequel::SQL::Constants::CURRENT_TIMESTAMP,
      :updated_at => Sequel::SQL::Constants::CURRENT_TIMESTAMP
    ).tap do |version_id|
      update_info_checksum(version_id)
    end
  end

  def insert_dependency(version_id, gem_name, requirements)
    Gemstash::Env.current.db[:dependencies].insert(
      :version_id => version_id,
      :rubygem_name => gem_name,
      :requirements => requirements,
      :created_at => Sequel::SQL::Constants::CURRENT_TIMESTAMP,
      :updated_at => Sequel::SQL::Constants::CURRENT_TIMESTAMP
    ).tap do
      update_info_checksum(version_id)
    end
  end

  def update_info_checksum(version_id)
    gem_id = Gemstash::Env.current.db[:versions][id: version_id][:rubygem_id]
    gem_name = Gemstash::Env.current.db[:rubygems][id: gem_id][:name]
    info = Gemstash::CompactIndexBuilder::Info.new(nil, gem_name).tap(&:build_result).result
    Gemstash::DB::Version.where(id: version_id).update(info_checksum: Digest::MD5.hexdigest(info))
    raise "Failed to update info checksum for version #{version_id}" unless Gemstash::Env.current.db[:versions][id: version_id][:info_checksum]
  end
end
