class CompanionOperationBody < ApplicationRecord

  belongs_to :companion_operation
  self.filter_attributes += [ :data ]

end
