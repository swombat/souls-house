Rails.application.config.to_prepare do
  # The test environment's cache store is a NullStore, which cannot count, so
  # a limiter there would admit everything. A memory store still refuses, and
  # a test process is the whole world for the limits it exercises.
  cache = Rails.cache.is_a?(ActiveSupport::Cache::NullStore) ? ActiveSupport::Cache::MemoryStore.new : Rails.cache
  ThrottleMachines.storage = ThrottleMachines::Storage::Cache.new(cache_store: cache)
  ThrottleMachines.configure do |config|
    config.default_algorithm = :fixed_window
    config.instrumentation_enabled = true
  end
end
