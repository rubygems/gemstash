module Gemstash
  # Module interfacing Gemstash plugins with Gemstash.
  module Plugins
    def register_plugin(plugin)
      plugins << plugin
    end

    def plugins
      @plugins ||= []
    end
  end
end
