# frozen_string_literal: true

require "spec_helper"
require "zlib"

RSpec.describe Gemstash::GemPusher do
  let(:auth) { Gemstash::ApiKeyAuthorization.new(auth_key) }
  let(:auth_with_invalid_auth_key) { Gemstash::ApiKeyAuthorization.new(invalid_auth_key) }
  let(:auth_without_permission) { Gemstash::ApiKeyAuthorization.new(auth_key_without_permission) }
  let(:auth_key) { "auth-key" }
  let(:invalid_auth_key) { "invalid-auth-key" }
  let(:auth_key_without_permission) { "auth-key-without-permission" }
  let(:storage) { Gemstash::Storage.for("private").for("gems") }

  before do
    Gemstash::Authorization.authorize(auth_key, "all")
    Gemstash::Authorization.authorize(auth_key_without_permission, ["yank"])
  end

  describe ".serve" do
    let(:deps) { Gemstash::Dependencies.for_private }
    let(:gem_contents) { read_gem("example", "0.1.0") }

    context "when called with a request" do
      let(:body) { StringIO.new(gem_contents) }
      let(:app) do
        double("app", auth: app_auth, request: double("request", body: body))
      end

      context "without authorization" do
        let(:app_auth) { auth_with_invalid_auth_key }

        it "rejects the push before reading the request body" do
          expect(body).to_not receive(:read)
          expect { Gemstash::GemPusher.serve(app) }.to raise_error(Gemstash::NotAuthorizedError)
          expect(deps.fetch(%w[example])).to eq([])
        end
      end

      context "without push permission" do
        let(:app_auth) { auth_without_permission }

        it "rejects the push before reading the request body" do
          expect(body).to_not receive(:read)
          expect { Gemstash::GemPusher.serve(app) }.to raise_error(Gemstash::NotAuthorizedError)
        end
      end

      context "with authorization" do
        let(:app_auth) { auth }

        it "reads the request body and stores the gem" do
          Gemstash::GemPusher.serve(app)
          expect(storage.resource("example-0.1.0").content(:gem)).to eq(gem_contents)
        end
      end
    end

    context "without authorization" do
      it "prevents pushing" do
        expect { Gemstash::GemPusher.new(Gemstash::ApiKeyAuthorization.new(nil), gem_contents).serve }.
          to raise_error(Gemstash::NotAuthorizedError)
        expect { Gemstash::GemPusher.new(Gemstash::ApiKeyAuthorization.new(""), gem_contents).serve }.
          to raise_error(Gemstash::NotAuthorizedError)
        expect(deps.fetch(%w[example])).to eq([])
      end
    end

    context "with invalid authorization" do
      it "prevents pushing" do
        expect { Gemstash::GemPusher.new(auth_with_invalid_auth_key, gem_contents).serve }.
          to raise_error(Gemstash::NotAuthorizedError)
        expect(deps.fetch(%w[example])).to eq([])
      end
    end

    context "with invalid permission" do
      it "prevents pushing" do
        expect { Gemstash::GemPusher.new(auth_without_permission, gem_contents).serve }.
          to raise_error(Gemstash::NotAuthorizedError)
        expect(deps.fetch(%w[example])).to eq([])
      end
    end

    context "with an unknown gem name" do
      it "saves the dependency info and stores the gem" do
        results = [{
          :name => "example",
          :number => "0.1.0",
          :platform => "ruby",
          :dependencies => [["sqlite3", "~> 1.3"],
                            ["thor", "~> 0.19"]]
        }]

        # Fetch before, asserting cache will be invalidated
        expect(deps.fetch(%w[example])).to eq([])
        Gemstash::GemPusher.new(auth, gem_contents).serve
        expect(deps.fetch(%w[example])).to match_dependencies(results)
        expect(storage.resource("example-0.1.0").content(:gem)).to eq(gem_contents)
      end

      it "stores the gemspec" do
        Gemstash::GemPusher.new(auth, gem_contents).serve
        spec = storage.resource("example-0.1.0").content(:spec)
        spec = Marshal.load(Zlib::Inflate.inflate(spec))
        expect(spec).to be_a(Gem::Specification)
        expect(spec.name).to eq("example")
        expect(spec.version.to_s).to eq("0.1.0")
        expect(spec.platform.to_s).to eq("ruby")
      end

      %i[gem spec].each do |failed_write|
        it "rolls back a failed #{failed_write} write and permits a retry", db_transaction: false do
          resource = storage.resource("example-0.1.0")
          fail_once = true
          allow(test_env).to receive(:atomic_write).and_wrap_original do |write, filename, &block|
            write.call(filename, &block)
            if fail_once && File.basename(filename) == failed_write.to_s
              fail_once = false
              raise IOError, "storage write failed"
            end
          end

          expect { Gemstash::GemPusher.new(auth, gem_contents).serve }.
            to raise_error(IOError, "storage write failed")
          expect(Gemstash::DB::Version.find_by_full_name("example-0.1.0")).to be_nil
          expect(Gemstash::DB::Rubygem[name: "example"]).to be_nil
          expect(Gemstash::DB::Dependency.count).to eq(0)
          expect(resource.exist?(:gem)).to be(false)
          expect(resource.exist?(:spec)).to be(false)
          expect(Dir.exist?(resource.folder)).to be(false)

          Gemstash::GemPusher.new(auth, gem_contents).serve
          expect(Gemstash::DB::Version.find_by_full_name("example-0.1.0").indexed).to be(true)
          expect(resource.content(:gem)).to eq(gem_contents)
          expect(resource.exist?(:spec)).to be(true)
        end
      end

      it "does not overwrite stored content with no version record", db_transaction: false do
        resource = storage.resource("example-0.1.0")
        resource.save({ gem: "orphan gem", spec: "orphan spec" }, indexed: true)

        expect { Gemstash::GemPusher.new(auth, gem_contents).serve }.
          to raise_error(Gemstash::GemPusher::ExistingVersionError)
        expect(Gemstash::DB::Version.find_by_full_name("example-0.1.0")).to be_nil
        expect(resource.content(:gem)).to eq("orphan gem")
        expect(resource.content(:spec)).to eq("orphan spec")
      end
    end

    context "with a non-ruby platform" do
      let(:gem_contents) { read_gem("example", "0.1.0-java") }

      it "saves the dependency info and stores the gem" do
        results = [{
          :name => "example",
          :number => "0.1.0",
          :platform => "java",
          :dependencies => [["sqlite3", "~> 1.3"],
                            ["thor", "~> 0.19"]]
        }]

        # Fetch before, asserting cache will be invalidated
        expect(deps.fetch(%w[example])).to eq([])
        Gemstash::GemPusher.new(auth, gem_contents).serve
        expect(deps.fetch(%w[example])).to match_dependencies(results)
        expect(storage.resource("example-0.1.0-java").content(:gem)).to eq(gem_contents)
      end

      it "stores the gemspec" do
        Gemstash::GemPusher.new(auth, gem_contents).serve
        spec = storage.resource("example-0.1.0-java").content(:spec)
        spec = Marshal.load(Zlib::Inflate.inflate(spec))
        expect(spec).to be_a(Gem::Specification)
        expect(spec.name).to eq("example")
        expect(spec.version.to_s).to eq("0.1.0")
        expect(spec.platform.to_s).to eq("java")
      end
    end

    context "with an exsiting gem name" do
      before do
        gem_id = insert_rubygem "example"
        insert_version gem_id, "0.0.1"
        storage.resource("example-0.0.1").save({ gem: "zapatito" }, indexed: true)
      end

      it "saves the new version dependency info and stores the gem" do
        results = [{
          :name => "example",
          :number => "0.0.1",
          :platform => "ruby",
          :dependencies => []
        }, {
          :name => "example",
          :number => "0.1.0",
          :platform => "ruby",
          :dependencies => [["sqlite3", "~> 1.3"],
                            ["thor", "~> 0.19"]]
        }]

        Gemstash::GemPusher.new(auth, gem_contents).serve
        expect(deps.fetch(%w[example])).to match_dependencies(results)
        expect(storage.resource("example-0.1.0").content(:gem)).to eq(gem_contents)
      end

      it "stores the gemspec" do
        Gemstash::GemPusher.new(auth, gem_contents).serve
        spec = storage.resource("example-0.1.0").content(:spec)
        spec = Marshal.load(Zlib::Inflate.inflate(spec))
        expect(spec).to be_a(Gem::Specification)
        expect(spec.name).to eq("example")
        expect(spec.version.to_s).to eq("0.1.0")
        expect(spec.platform.to_s).to eq("ruby")
      end
    end

    context "with a yanked version" do
      before do
        gem_id = insert_rubygem "example"
        insert_version gem_id, "0.1.0", indexed: false
        storage.resource("example-0.1.0").save({ gem: "zapatito", spec: "original spec" }, indexed: false)
      end

      it "rejects the push and does not change the stored gem or gemspec" do
        expect do
          expect { Gemstash::GemPusher.new(auth, gem_contents).serve }.
            to raise_error(Gemstash::GemPusher::YankedVersionError)
        end.to_not change { storage.resource("example-0.1.0").content(:gem) }.from("zapatito")
        expect(storage.resource("example-0.1.0").content(:spec)).to eq("original spec")
        expect(storage.resource("example-0.1.0").properties[:indexed]).to be(false)
      end
    end

    context "with an existing version" do
      let(:serve) { Gemstash::GemPusher.new(auth, gem_contents).serve }

      before do
        gem_id = insert_rubygem "example"
        insert_version gem_id, "0.1.0"
        storage.resource("example-0.1.0").save({ gem: "zapatito" }, indexed: true)
      end

      it "rejects the push and does not change the file content" do
        expect do
          expect { serve }.to raise_error(Gemstash::GemPusher::ExistingVersionError)
        end.to_not change { storage.resource("example-0.1.0").content(:gem) }.from("zapatito")
      end

      it "does not overwrite the gem content" do
        expect { Gemstash::GemPusher.new(auth, gem_contents).serve }.
          to raise_error(Gemstash::GemPusher::ExistingVersionError)

        expect(storage.resource("example-0.1.0").content(:gem)).
          to eq("zapatito")
      end
    end
  end
end
