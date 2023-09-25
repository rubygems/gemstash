# frozen_string_literal: true

require "gemstash"

module Gemstash
  module DB
    # Sequel model for authorizations table.
    class Authorization < Sequel::Model
      def self.insert_or_update(auth_key, permissions, name = nil)
        db.transaction do
          record = self[auth_key: auth_key]

          if record
            record.update(permissions: permissions, name: name)
          else
            create(auth_key: auth_key, permissions: permissions, name: name)
          end
        end
      end
    end
  end
end
