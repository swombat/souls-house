module ApplicationCable
  class Channel < ActionCable::Channel::Base

    before_subscribe :refuse_unrelated_device

    def self.companion_device_channel?
      false
    end

    private

    def refuse_unrelated_device
      reject if connection.respond_to?(:current_companion_device) &&
        connection.current_companion_device && !self.class.companion_device_channel?
      throw :abort if subscription_rejected?
    end

  end
end
