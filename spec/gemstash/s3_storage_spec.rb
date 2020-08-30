# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "aws-sdk-s3"

RSpec.describe Gemstash::S3 do
  before(:all) do
    VCR.use_cassette("initialize S3 storage variable") do
      @storage = Gemstash::S3.for("TEST_S3_SPEC_FOLDER").for("private").for("gems")
      @folder = "gemstash/s3_storage"
    end
  end
  after(:all) do
    VCR.use_cassette("batch delete objects") do
      delete_with_prefix(@storage.s3_resource_object, @storage.folder)
    end
  end

  context "intialize storage component" do
    it("builds with a valid folder") {
      Gemstash::S3.new("test")
      expect(Gemstash::S3.new(@folder)).not_to be_nil
    }
    it "stores metadata about Gemstash and the storage engine version" do
      expect(Gemstash::S3.metadata[:storage_version]).to eq(Gemstash::S3::STORAGE_VERSION)
      expect(Gemstash::S3.metadata[:gemstash_version]).to eq(Gemstash::VERSION)
    end

    it "prevents using storage engine if the storage version is too new" do
      metadata = {
        storage_version: 999_999,
        gemstash_version: Gemstash::VERSION
      }
      File.write(Gemstash::Env.current.base_file("metadata.yml"), metadata.to_yaml)
      expect { Gemstash::S3.new(@folder) }.
        to raise_error(Gemstash::S3::VersionTooNewError)
    end
  end

  context "with a valid storage" do
    let(:gem_contents) { read_gem("example", "0.1.0") }
    before(:context) do
    end
    it "can create a child storage from itself" do
      child_storage = @storage.for("gems")
      expect(child_storage).to be_truthy
      expect(child_storage).to be_instance_of Gemstash::S3
      expect(child_storage.folder).to eq(File.join(@storage.folder, "gems"))
    end

    it "returns a non existing resource when requested", :vcr do
      resource = @storage.resource("an_id")
      expect(resource).not_to be_nil
      expect(resource).not_to exist
    end

    it "auto sets gemstash version property, even when properties not saved", :vcr do
      resource = @storage.resource("something")
      resource = resource.save(content: "some content")
      expect(resource.properties).to eq(gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "won't update gemstash version when already stored", :vcr do
      @storage.resource("42").save({ content: "content" }, gemstash_resource_version: 0)
      expect(@storage.resource("42").properties[:gemstash_resource_version]).to eq(0)
      @storage.resource("42").update_properties(key: "value")
      expect(@storage.resource("42").properties[:gemstash_resource_version]).to eq(0)
    end

    it "won't load a resource that is at a larger version than our current version", :vcr do
      @storage.resource("43").save({ content: "content" }, gemstash_resource_version: 999_999)
      expect { @storage.resource("43").content(:content) }.to raise_error(Gemstash::S3Resource::VersionTooNewError, /43/)
    end
  end
  context "with a simple resource" do
    it "can be saved", :vcr do
      resource = @storage.resource("test1")
      resource.save(content: "content")
      expect(resource.content(:content)).to eq("content")
    end

    it "can be read afterwards", :vcr do
      resource = @storage.resource("test2")
      resource.save(content: "some content")
      expect(resource.content(:content)).to eq("some content")
    end

    it "can also save properties", :vcr do
      resource = @storage.resource("test3")
      resource.save({ content: "some other content" }, "content-type" => "octet/stream")
      expect(resource.content(:content)).to eq("some other content")
      expect(resource.properties).to eq("content-type" => "octet/stream",
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "can save nested properties", :vcr do
      resource = @storage.resource("test4")
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
      @storage.resource(resource_id).save(content: content)
    end
    it "loads the content from storage", :vcr do
      resource = @storage.resource(resource_id)
      expect(resource.content(:content)).to eq(content)
    end

    it "can have properties updated", :vcr do
      resource = @storage.resource(resource_id)
      resource.update_properties(key: "value", other: :value)
      expect(@storage.resource(resource_id).properties).
        to eq(key: "value", other: :value, gemstash_resource_version: Gemstash::S3Resource::VERSION)
      resource = @storage.resource(resource_id)
      resource.update_properties(key: "new", new: 45)
      expect(@storage.resource(resource_id).properties).
        to eq(key: "new", other: :value, new: 45, gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "can merge nested properties", :vcr do
      resource = @storage.resource("46")
      resource.save({ gem: "some gem content" }, headers: { gem: { foo: "bar" } })
      resource.save({ spec: "some spec content" }, headers: { spec: { foo: "baz" } })
      expect(resource.properties).to eq(headers: { gem: { foo: "bar" }, spec: { foo: "baz" } },
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
      resource.save({ spec: "some spec content" }, headers: { spec: { foo: "changed" } })
      expect(resource.properties).to eq(headers: { gem: { foo: "bar" }, spec: { foo: "changed" } },
                                        gemstash_resource_version: Gemstash::S3Resource::VERSION)
    end

    it "can be deleted", :vcr do
      resource = @storage.resource(resource_id)
      resource.delete(:content)
      expect(resource.exist?(:content)).to be_falsey
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)
      # Fetching the resource again will still prevent access
      resource = @storage.resource(resource_id)
      expect(resource.exist?(:content)).to be_falsey
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)

      # Ensure properties is deleted
      properties_filename = File.join(resource.folder, "properties.yml")
      expect(File.exist?(properties_filename)).to be_falsey
    end
  end
  context "storing multiple files in one resource" do
    let(:content) { "zapatito" }
    let(:other_content) { "foobar" }

    it "can be done in 1 save", :vcr do
      resource = @storage.resource("47")
      resource.save(content: content, other_content: other_content)
      expect(resource.content(:content)).to eq(content)
      expect(resource.content(:other_content)).to eq(other_content)

      resource = @storage.resource("47")
      expect(resource.content(:content)).to eq(content)
      expect(resource.content(:other_content)).to eq(other_content)
    end

    it "can be done in 2 saves", :vcr do
      resource = @storage.resource("49")
      resource.save(content: content).save(other_content: other_content)
      expect(resource.content(:content)).to eq(content)
      expect(resource.content(:other_content)).to eq(other_content)

      resource = @storage.resource("49")
      expect(resource.content(:content)).to eq(content)
      expect(resource.content(:other_content)).to eq(other_content)
    end

    it "can be done in 2 saves with separate properties defined", :vcr do
      resource = @storage.resource("50")
      resource.save({ content: content }, foo: "bar").save({ other_content: other_content }, bar: "baz")
      expect(resource.properties).to eq(foo: "bar", bar: "baz", gemstash_resource_version: Gemstash::Resource::VERSION)

      resource = @storage.resource("50")
      expect(resource.properties).to eq(foo: "bar", bar: "baz", gemstash_resource_version: Gemstash::Resource::VERSION)
    end

    it "can be done in 2 saves with nil properties defined on second", :vcr do
      resource = @storage.resource("51")
      resource.save({ content: content }, foo: "bar").save(other_content: other_content)
      expect(resource.properties).to eq(foo: "bar", gemstash_resource_version: Gemstash::Resource::VERSION)

      resource = @storage.resource("51")
      expect(resource.properties).to eq(foo: "bar", gemstash_resource_version: Gemstash::Resource::VERSION)
    end

    it "can be done in 2 saves with separate properties defined from separate resource instances", :vcr do
      @storage.resource("52").save({ content: content }, foo: "bar")
      resource = @storage.resource("52")
      resource.save({ other_content: other_content }, bar: "baz")
      expect(resource.properties).to eq(foo: "bar", bar: "baz", gemstash_resource_version: Gemstash::Resource::VERSION)

      resource = @storage.resource("52")
      expect(resource.properties).to eq(foo: "bar", bar: "baz", gemstash_resource_version: Gemstash::Resource::VERSION)
    end

    it "supports 1 file being deleted", :vcr do
      @storage.resource("53").save({ content: content, other_content: other_content }, foo: "bar")
      resource = @storage.resource("53")
      resource.delete(:content)
      expect(resource.exist?(:content)).to be_falsey
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)

      resource = @storage.resource("53")
      expect(resource.content(:other_content)).to eq(other_content)
      expect(resource.properties).to eq(foo: "bar", gemstash_resource_version: Gemstash::Resource::VERSION)
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)
    end

    it "supports both files being deleted", :vcr do
      @storage.resource("54").save({ content: content, other_content: other_content }, foo: "bar")
      resource = @storage.resource("54")
      resource.delete(:content).delete(:other_content)
      resource.properties
      expect(resource.exist?(:content)).to be_falsey
      expect(resource.exist?(:other_content)).to be_falsey
      resource.exist?
      expect(resource).to_not exist
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)
      expect { resource.content(:other_content) }.to raise_error(/no :other_content content to load/)

      resource = @storage.resource("54")
      expect(resource.exist?(:content)).to be_falsey
      expect(resource.exist?(:other_content)).to be_falsey
      expect(resource).to_not exist
      expect { resource.content(:content) }.to raise_error(/no :content content to load/)
      expect { resource.content(:other_content) }.to raise_error(/no :other_content content to load/)

      # Ensure properties is deleted
      properties_filename = File.join(resource.folder, "properties.yml")
      expect(File.exist?(properties_filename)).to be_falsey
    end
  end
  context "with resource name that is unique by case only", :vcr do
    let(:first_resource_id) { "SomeResource" }
    let(:second_resource_id) { "someresource" }

    it "stores the content separately" do
      @storage.resource(first_resource_id).save(content: "first content")
      @storage.resource(second_resource_id).save(content: "second content")
      expect(@storage.resource(first_resource_id).content(:content)).to eq("first content")
      expect(@storage.resource(second_resource_id).content(:content)).to eq("second content")
    end

    it "uses different downcased paths to avoid issues with case insensitive file systems" do
      first_resource = @storage.resource(first_resource_id)
      second_resource = @storage.resource(second_resource_id)
      expect(first_resource.folder.downcase).to_not eq(second_resource.folder.downcase)
    end
  end

  context "with resource name that includes odd characters", :vcr do
    let(:resource_id) { ".=$&resource" }

    it "stores and retrieves the data" do
      @storage.resource(resource_id).save(content: "odd name content")
      expect(@storage.resource(resource_id).content(:content)).to eq("odd name content")
    end

    it "doesn't include the odd characters in the path" do
      expect(@storage.resource(resource_id).folder).to_not match(/[.=$&]/)
    end
  end

  describe "#property?", :vcr do
    let(:resource) { @storage.resource("existing") }

    context "with a single key" do
      before do
        resource.save({ file: "content" }, foo: "one", bar: nil, baz: { qux: "two" })
      end

      it "returns true for a valid key" do
        expect(resource.property?(:foo)).to eq(true)
      end

      it "returns true for a key pointing to explicit nil" do
        expect(resource.property?(:bar)).to eq(true)
      end

      it "returns true for a key pointing to a nested hash" do
        expect(resource.property?(:baz)).to eq(true)
      end

      it "returns false if the resource doesn't exist" do
        expect(@storage.resource("missing").property?(:foo)).to eq(false)
      end

      it "returns false for a missing key" do
        expect(resource.property?(:missing)).to eq(false)
      end
    end
  end
end
