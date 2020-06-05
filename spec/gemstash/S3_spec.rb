# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "pry"
require "byebug"

RSpec.describe Gemstash::S3 do
  let(:storage) { Gemstash::S3.new("gemstash/S3_storage_tests",Gemstash::Env.current).for("private").for("gems") }
  before do
    @folder = Dir.mktmpdir
  end
  after(:all) do
    VCR.use_cassette('batch_delete objects') do
      Gemstash::S3.new("gemstash/S3_storage_tests",Gemstash::Env.current).bucket.objects(prefix: "gemstash/S3_storage_tests/private/gems").batch_delete!
    end
  end

  context "intialize storage component" do
    it "builds with a valid folder" do
      expect(Gemstash::S3.new(@folder,Gemstash::Env.current)).not_to be_nil
    end

    it "stores metadata about Gemstash and the storage engine version" do
      expect(Gemstash::S3.metadata[:storage_version]).to eq(Gemstash::S3::VERSION)
      expect(Gemstash::S3.metadata[:gemstash_version]).to eq(Gemstash::VERSION)
    end

    it "prevents using storage engine if the storage version is too new" do
      metadata = {
          storage_version: 999_999,
          gemstash_version: Gemstash::VERSION
      }
      File.write(Gemstash::Env.current.base_file("metadata.yml"), metadata.to_yaml)
      expect { Gemstash::S3.new(@folder,Gemstash::Env.current) }.
          to raise_error(Gemstash::S3::VersionTooNew)
    end
  end
  context "with a valid storage" do
    let(:gem_contents) { read_gem("example", "0.1.0") }
    it "can create a child storage from itself" do
      child_storage = storage.for("gems")
      expect(child_storage).to be_truthy
      expect(child_storage).to be_instance_of Gemstash::S3
      expect(child_storage.folder).to eq(File.join(storage.folder, "gems"))
    end

    it "returns a non existing resource when requested",:vcr do
      resource = storage.resource("an_id")
      expect(resource).not_to be_nil
      expect(resource).not_to exist
    end

    it "auto sets gemstash version property, even when properties not saved", :vcr do
      resource = storage.resource("something")
      resource = resource.save(content: "some content")
      expect(resource.properties).to eq(gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "won't update gemstash version when already stored", :vcr do
      storage.resource("42").save({ content: "content" }, gemstash_resource_version: 0)
      expect(storage.resource("42").properties[:gemstash_resource_version]).to eq(0)
      storage.resource("42").update_properties(key: "value")
      expect(storage.resource("42").properties[:gemstash_resource_version]).to eq(0)
    end

  end
  context "with a simple resource" do
    it "can be saved", :vcr do
      resource = storage.resource("test1")
      resource.save(content: "content")
      expect(resource.content(:content)).to eq("content")
    end

    it "can be read afterwards", :vcr do
      resource = storage.resource("test2")
      resource.save(content: "some content")
      expect(resource.content(:content)).to eq("some content")
    end

    it "can also save properties", :vcr do
      resource = storage.resource("test3")
      resource.save({ content: "some other content" }, "content-type" => "octet/stream")
      expect(resource.content(:content)).to eq("some other content")
      expect(resource.properties).to eq("content-type" => "octet/stream",
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "can save nested properties", :vcr do
      resource = storage.resource("test4")
      resource.save({ content: "some other content" }, headers: { "content-type" => "octet/stream" })
      expect(resource.content(:content)).to eq("some other content")
      expect(resource.properties).to eq(headers: { "content-type" => "octet/stream" },
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end
  end
  context "with a previously stored resource" do
    let(:resource_id) { "44" }
    let(:content) { "zapatito" }
    before do
      storage.resource(resource_id).save(content: content)
    end
    it "loads the content from storage",:vcr do
      resource = storage.resource(resource_id)
      expect(resource.content(:content)).to eq(content)
    end

    it "can have properties updated",:vcr do
      resource = storage.resource(resource_id)
      resource.update_properties(key: "value", other: :value)
      expect(storage.resource(resource_id).properties).
          to eq(key: "value", other: :value, gemstash_resource_version: Gemstash::S3Resource::VERSION)
      resource = storage.resource(resource_id)
      resource.update_properties(key: "new", new: 45)
      expect(storage.resource(resource_id).properties).
          to eq(key: "new", other: :value, new: 45, gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "can merge nested properties",:vcr do
      resource = storage.resource("46")
      resource.save({ gem: "some gem content" }, headers: { gem: { foo: "bar" } })
      resource.save({ spec: "some spec content" }, headers: { spec: { foo: "baz" } })
      expect(resource.properties).to eq(headers: { gem: { foo: "bar" }, spec: { foo: "baz" } },
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
      resource.save({ spec: "some spec content" }, headers: { spec: { foo: "changed" } })
      expect(resource.properties).to eq(headers: { gem: { foo: "bar" }, spec: { foo: "changed" } },
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "can be deleted", :vcr do
      resource = storage.resource(resource_id)
      resource.delete(:content)
      expect(resource.exist?(:content)).to be_falsey
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)
      # Fetching the resource again will still prevent access
      resource = storage.resource(resource_id)
      expect(resource.exist?(:content)).to be_falsey
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)

      # Ensure properties is deleted
      properties_filename = File.join(resource.folder, "properties.yml")
      expect(File.exist?(properties_filename)).to be_falsey
    end
  end
end
