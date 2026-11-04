module Message::Streamable

  extend ActiveSupport::Concern

  def stream_content(chunk)
    chunk = chunk.to_s
    return if chunk.empty?

    update_columns(streaming: true, content: (content.to_s + chunk))

    Rails.logger.debug "Broadcasting streaming update to Message:#{to_param}:stream (length: #{content.to_s.length}, chunk: #{chunk})"
    broadcast_marker(
      "Message:#{to_param}",
      {
        action: "streaming_update",
        chunk: chunk,
        id: to_param
      }
    )
  end

  def stream_thinking(chunk)
    chunk = chunk.to_s
    return if chunk.empty?

    update_columns(thinking_text: (thinking_text.to_s + chunk))

    broadcast_marker(
      "Message:#{to_param}",
      {
        action: "thinking_update",
        chunk: chunk,
        id: to_param
      }
    )
  end

  def stop_streaming
    Rails.logger.info "Stopping streaming for Message:#{to_param}, currently streaming: #{streaming?}"

    if streaming?
      update!(streaming: false, tool_status: nil)
      Rails.logger.info "Message #{to_param} updated to streaming: false"
    end

    broadcast_marker(
      "Message:#{to_param}",
      {
        action: "streaming_end",
        chunk: nil,
        id: to_param
      }
    )
    broadcast_marker(
      "Chat:#{chat.obfuscated_id}",
      {
        action: "streaming_end",
        chunk: nil,
        id: to_param
      }
    )
    Rails.logger.info "Broadcasted streaming_end to Message:#{to_param} and Chat:#{chat.obfuscated_id}"
  end

  def broadcast_tool_call(tool_name:, tool_args:)
    status = format_tool_status(tool_name, tool_args)
    Rails.logger.debug "Updating tool status: #{status}"
    update!(tool_status: status)
  end

  private

  def format_tool_status(tool_name, tool_args)
    case tool_name
    when "WebFetchTool", "web_fetch"
      url = tool_args[:url] || tool_args["url"]
      "Fetching #{truncate_url(url)}"
    when "WebSearchTool", "web_search"
      query = tool_args[:query] || tool_args["query"]
      "Searching for \"#{query}\""
    else
      "Using #{tool_name.to_s.underscore.humanize.downcase}"
    end
  end

  def truncate_url(url)
    return url if url.nil? || url.length <= 50
    "#{url[0..47]}..."
  end

end
