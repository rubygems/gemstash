# frozen_string_literal: true

require "gemstash"

# Helper method to delete multiple objects in S3 storage

module S3Helpers
  def delete_with_prefix(resource, prefix)
    resource.objects(prefix: prefix).batch_delete!
  end
end
