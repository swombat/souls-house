# The cache rate limits count in. Rails.cache everywhere; tests that check a
# limit swap in a MemoryStore (the test environment's cache is a null store,
# which never counts). rate_limit captures its store when the class loads,
# so it gets this delegator rather than a store.
module RateLimitStore

  mattr_accessor :override

  def self.increment(...)
    (override || Rails.cache).increment(...)
  end

end
