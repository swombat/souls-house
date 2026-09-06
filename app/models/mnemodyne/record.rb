# Graph IDs are portable UUIDs. ApplicationRecord's integer Hashids encoding
# does not apply to this subsystem (including association find and JSON IDs).
class Mnemodyne::Record < ActiveRecord::Base

  self.abstract_class = true

  # A paused filesystem/upload must not park resident API threads indefinitely.
  # The savepoint rolls back SET LOCAL on failure, including a lock timeout.
  def with_lock(*args, &block)
    self.class.transaction(requires_new: true) do
      connection = self.class.connection
      previous = connection.select_value("SHOW lock_timeout")
      connection.execute("SET LOCAL lock_timeout = '2s'")
      result = super(*args, &block)
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(previous)}")
      result
    end
  end

end
