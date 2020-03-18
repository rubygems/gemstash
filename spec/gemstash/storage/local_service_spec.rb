# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe Gemstash::Storage::LocalService do
  before do
    @folder = Dir.mktmpdir
  end
  after do
    FileUtils.remove_entry(@folder) if File.exist?(@folder)
  end

  pending
end
