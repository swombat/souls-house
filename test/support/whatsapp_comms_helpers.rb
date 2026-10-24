require "support/telegram_comms_helpers"

# A fake WhatsApp connector: every setting a WhatsApp command needs
# (CommsConnector::WHATSAPP_ENV), with the throwaway mutual-TLS material from
# TelegramCommsHelpers, and Net::HTTP stubbed to record each request.
module WhatsappCommsHelpers

  def with_whatsapp_connector(url: "https://souls-house-comms-whatsapp:8443", key: "test-command-key",
                              tls: TelegramCommsHelpers::TLS_ENV, status: 200, stub_http: true)
    names = CommsConnector::WHATSAPP_ENV
    previous = ENV.to_h.slice(*names)
    ENV[CommsConnector::WHATSAPP_URL_ENV] = url
    ENV["COMMS_COMMAND_KEY"] = key
    TelegramCommsHelpers::TLS_ENV.each do |name|
      ENV[name] = tls.include?(name) ? TelegramCommsHelpers.tls_files.fetch(name) : nil
    end
    return yield([], []) unless stub_http

    requests = []
    options_seen = []
    fake = Object.new
    fake.define_singleton_method(:request) do |request|
      requests << request
      Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "").tap do |response|
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, "{}")
      end
    end
    Net::HTTP.stub(:start, ->(_host, _port, **options, &block) { options_seen << options; block.call(fake) }) do
      yield requests, options_seen
    end
  ensure
    names.each { |name| ENV[name] = previous[name] }
  end

end
