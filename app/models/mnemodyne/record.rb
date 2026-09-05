# Graph IDs are portable UUIDs. ApplicationRecord's integer Hashids encoding
# does not apply to this subsystem (including association find and JSON IDs).
class Mnemodyne::Record < ActiveRecord::Base

  self.abstract_class = true

end
