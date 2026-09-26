class DeviceStreamSession < ApplicationRecord

  belongs_to :device_stream
  has_many :device_stream_batches, dependent: :delete_all

end
