# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "yaml"

RSpec.describe Gemstash::CLI::Authorize do
  before do
    # Don't let the environment change, else we get a separate test db
    # connection, which messes up the tests
    allow(Gemstash::Env).to receive(:current=).and_return(nil)
    # Don't let the config change, so we don't reload the DB or anything
    allow_any_instance_of(Gemstash::Env).to receive(:config=).and_return(nil)
  end

  let(:cli) do
    @said = ""
    result = double(:options => cli_options)

    allow(result).to receive(:say) do |x|
      @said += "#{x}\n"
      nil
    end

    allow(result).to receive(:set_color) {|x| x }
    result
  end

  let(:cli_options) { {} }

  context "authorizing with just the auth key" do
    let(:cli_options) { { :key => "auth-key" } }

    it "authorizes the key for all permissions" do
      Gemstash::CLI::Authorize.new(cli).run
      expect(Gemstash::Authorization["auth-key"].all?).to be_truthy
    end
  end

  context "authorizing with the auth key and permissions" do
    let(:cli_options) { { :key => "auth-key" } }

    it "authorizes the key for just the given permissions" do
      Gemstash::CLI::Authorize.new(cli, "push", "yank").run
      auth = Gemstash::Authorization["auth-key"]
      expect(auth.all?).to be_falsey
      expect(auth.push?).to be_truthy
      expect(auth.yank?).to be_truthy
    end
  end

  context "authorizing without specifying the key" do
    it "outputs the new key and authorizes for all permissions" do
      expect(SecureRandom).to receive(:hex).and_return("new-auth-key")
      Gemstash::CLI::Authorize.new(cli).run
      expect(@said).to include("new-auth-key")
      expect(Gemstash::Authorization["new-auth-key"].all?).to be_truthy
    end
  end

  context "authorizing with a name without specifying the key" do
    let(:cli_options) { { :name => "test auth" } }

    it "saves a new key with the given name" do
      expect(SecureRandom).to receive(:hex).and_return("new-auth-key")
      Gemstash::CLI::Authorize.new(cli).run
      expect(@said).to include("new-auth-key")
      authorization = Gemstash::Authorization["new-auth-key"]
      expect(authorization.all?).to be_truthy
      expect(authorization.name).to eq "test auth"
    end
  end

  context "authorizing without specifying the key and with permissions" do
    it "outputs the new key and authorizes for the given permissions" do
      expect(SecureRandom).to receive(:hex).and_return("new-auth-key")
      Gemstash::CLI::Authorize.new(cli, "push", "yank").run
      expect(@said).to include("new-auth-key")
      auth = Gemstash::Authorization["new-auth-key"]
      expect(auth.all?).to be_falsey
      expect(auth.push?).to be_truthy
      expect(auth.yank?).to be_truthy
    end
  end

  context "a random auth key coming up more than once" do
    before do
      Gemstash::Authorization.authorize("existing-auth-key", "all")
    end

    it "continues to generate a key until a unique one is generated" do
      expect(SecureRandom).to receive(:hex).and_return("existing-auth-key")
      expect(SecureRandom).to receive(:hex).and_return("existing-auth-key")
      expect(SecureRandom).to receive(:hex).and_return("new-auth-key")
      Gemstash::CLI::Authorize.new(cli, "push", "yank").run
      expect(@said).to include("new-auth-key")
      expect(Gemstash::Authorization["existing-auth-key"].all?).to be_truthy
      auth = Gemstash::Authorization["new-auth-key"]
      expect(auth.all?).to be_falsey
      expect(auth.push?).to be_truthy
      expect(auth.yank?).to be_truthy
    end
  end

  context "authorizing an existing auth key" do
    let(:cli_options) { { :key => "auth-key" } }

    before do
      Gemstash::Authorization.authorize("auth-key", %w[yank])
    end

    it "updates the permissions" do
      Gemstash::CLI::Authorize.new(cli, "push", "yank").run
      auth = Gemstash::Authorization["auth-key"]
      expect(auth.all?).to be_falsey
      expect(auth.push?).to be_truthy
      expect(auth.yank?).to be_truthy
    end

    it "updates the name" do
      cli_options[:name] = "test auth"
      Gemstash::CLI::Authorize.new(cli).run
      auth = Gemstash::Authorization["auth-key"]
      expect(auth.name).to eq "test auth"
    end
  end

  context "with the --remove option" do
    let(:cli_options) { { :key => "auth-key", :remove => true } }

    before do
      Gemstash::Authorization.authorize("auth-key", %w[yank])
    end

    it "removes the authorization" do
      Gemstash::CLI::Authorize.new(cli).run
      expect(Gemstash::Authorization["auth-key"]).to be_nil
    end

    it "combined with --list results in an error" do
      cli_options[:list] = true
      expect { Gemstash::CLI::Authorize.new(cli).run }.to raise_error(Gemstash::CLI::Error)
      expect(Gemstash::Authorization["auth-key"]).to be # Auth was not actually removed
    end

    it "combined with --name results in an error" do
      cli_options[:name] = "test auth"
      expect { Gemstash::CLI::Authorize.new(cli).run }.to raise_error(Gemstash::CLI::Error)
      expect(Gemstash::Authorization["auth-key"]).to be # Auth was not actually removed
    end
  end

  context "with invalid permissions" do
    let(:cli_options) { { :key => "auth-key" } }

    it "gives the user an error" do
      expect { Gemstash::CLI::Authorize.new(cli, "all").run }.to raise_error(Gemstash::CLI::Error)
      expect { Gemstash::CLI::Authorize.new(cli, "invalid").run }.to raise_error(Gemstash::CLI::Error)
      expect(Gemstash::Authorization["auth-key"]).to be_nil
    end
  end

  context "with --remove option and permissions" do
    let(:cli_options) { { :key => "auth-key", :remove => true } }

    before do
      Gemstash::Authorization.authorize("auth-key", %w[yank])
    end

    it "gives the user an error" do
      expect { Gemstash::CLI::Authorize.new(cli, "push").run }.to raise_error(Gemstash::CLI::Error)
      expect(Gemstash::Authorization["auth-key"]).to be
    end
  end

  context "with --remove option and no --key" do
    let(:cli_options) { { :remove => true } }

    it "gives the user an error" do
      expect { Gemstash::CLI::Authorize.new(cli).run }.to raise_error(Gemstash::CLI::Error)
    end
  end

  context "with the --list option" do
    let(:cli_options) { { :list => true } }

    it "lists un-named authorizations" do
      Gemstash::Authorization.authorize("auth-key-all", "all")
      Gemstash::Authorization.authorize("auth-key-push", %w[push])
      Gemstash::Authorization.authorize("auth-key-yank", %w[yank])
      Gemstash::Authorization.authorize("auth-key-fetch", %w[fetch])

      Gemstash::CLI::Authorize.new(cli).run
      expect(@said).to match(/auth-key-all.*all/)
      expect(@said).to match(/auth-key-push.*push/)
      expect(@said).to match(/auth-key-yank.*yank/)
      expect(@said).to match(/auth-key-fetch.*fetch/)
    end

    it "lists named authorizations" do
      Gemstash::Authorization.authorize("auth-key-all", "all", "auth all")
      Gemstash::Authorization.authorize("auth-key-push", %w[push], "auth push")
      Gemstash::Authorization.authorize("auth-key-yank", %w[yank], "auth yank")
      Gemstash::Authorization.authorize("auth-key-fetch", %w[fetch], "auth fetch")

      Gemstash::CLI::Authorize.new(cli).run
      expect(@said).to match(/auth all.*auth-key-all.*all/)
      expect(@said).to match(/auth push.*auth-key-push.*push/)
      expect(@said).to match(/auth yank.*auth-key-yank.*yank/)
      expect(@said).to match(/auth fetch.*auth-key-fetch.*fetch/)
    end

    it "lists specific authorization by name" do
      Gemstash::Authorization.authorize("auth-key-all", "all", "auth all")
      Gemstash::Authorization.authorize("auth-key-push", %w[push], "auth push")
      cli_options[:name] = "auth push"

      Gemstash::CLI::Authorize.new(cli).run
      expect(@said).not_to match(/auth all.*auth-key-all.*all/)
      expect(@said).to match(/auth push.*auth-key-push.*push/)
    end

    it "lists specific authorization by key" do
      Gemstash::Authorization.authorize("auth-key-all", "all", "auth all")
      Gemstash::Authorization.authorize("auth-key-push", %w[push], "auth push")
      cli_options[:key] = "auth-key-push"

      Gemstash::CLI::Authorize.new(cli).run
      expect(@said).not_to match(/auth all.*auth-key-all.*all/)
      expect(@said).to match(/auth push.*auth-key-push.*push/)
    end

    it "errors when auth is specified by both name and key" do
      Gemstash::Authorization.authorize("auth-key-all", "all", "auth all")
      Gemstash::Authorization.authorize("auth-key-push", %w[push], "auth push")
      cli_options[:name] = "auth push"
      cli_options[:key] = "auth-key-push"

      expect { Gemstash::CLI::Authorize.new(cli).run }.to raise_error(Gemstash::CLI::Error)
    end

    it "handles missing authorization" do
      Gemstash::Authorization.authorize("auth-key-all", "all", "auth all")
      Gemstash::Authorization.authorize("auth-key-push", %w[push], "auth push")
      cli_options[:name] = "missing name"

      expect { Gemstash::CLI::Authorize.new(cli).run }.to raise_error(Gemstash::CLI::Error)
    end
  end
end
