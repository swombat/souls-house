# RubyLLM Error Handling Documentation

## Version Information
- Documentation source: https://rubyllm.com/error-handling/
- Related sources: https://rubyllm.com/rails/, https://rubyllm.com/async/
- Fetched: 2025-10-05

## Key Concepts

### Error Hierarchy
RubyLLM provides a comprehensive error hierarchy that maps to HTTP status codes and specific failure scenarios:

```ruby
RubyLLM::Error                    # Base error class
├── RubyLLM::ConfigurationError   # Invalid configuration
├── RubyLLM::ModelNotFoundError   # Model not available
├── RubyLLM::BadRequestError      # 400 - Invalid request format
├── RubyLLM::UnauthorizedError    # 401 - Authentication failure
├── RubyLLM::ForbiddenError       # 403 - Permission denied
├── RubyLLM::NotFoundError        # 404 - Resource not found
├── RubyLLM::RateLimitError       # 429 - Rate limit exceeded
├── RubyLLM::ServerError          # 500 - Provider server error
├── RubyLLM::TimeoutError         # Request timeout
├── RubyLLM::NetworkError         # Network connectivity issues
└── RubyLLM::ValidationError      # Input validation failures
```

### Error Categories

#### 1. Authentication and Authorization Errors
- **UnauthorizedError**: Invalid API keys, expired tokens
- **ForbiddenError**: Insufficient permissions, usage limits exceeded

#### 2. Request Validation Errors
- **BadRequestError**: Malformed requests, invalid parameters
- **ValidationError**: Input validation failures
- **ModelNotFoundError**: Requested model not available

#### 3. Rate Limiting and Capacity Errors
- **RateLimitError**: API rate limits exceeded
- **ServerError**: Provider capacity issues, temporary unavailability

#### 4. Network and Infrastructure Errors
- **TimeoutError**: Request timeouts, slow responses
- **NetworkError**: Connectivity issues, DNS failures

#### 5. Configuration Errors
- **ConfigurationError**: Missing API keys, invalid settings

### Automatic Retry Mechanisms
RubyLLM implements intelligent retry logic for recoverable errors:

```ruby
# Default retry configuration
RubyLLM.configure do |config|
  config.max_retries = 3
  config.retry_delay = 1.0          # Initial delay in seconds
  config.retry_multiplier = 2.0     # Exponential backoff multiplier
  config.max_retry_delay = 30.0     # Maximum retry delay

  # Customize which errors to retry
  config.retryable_errors = [
    RubyLLM::RateLimitError,
    RubyLLM::ServerError,
    RubyLLM::TimeoutError,
    RubyLLM::NetworkError
  ]
end
```

## Implementation Guide

### Step 1: Basic Error Handling Patterns

#### Simple Error Handling
```ruby
class ChatController < ApplicationController
  def create_message
    chat = Chat.find(params[:chat_id])

    begin
      response = chat.ask(params[:message])

      render json: {
        content: response.content,
        tokens: response.tokens
      }
    rescue RubyLLM::UnauthorizedError => e
      render json: {
        error: "Authentication failed. Please check your API configuration.",
        type: "authentication_error"
      }, status: :unauthorized

    rescue RubyLLM::RateLimitError => e
      render json: {
        error: "Rate limit exceeded. Please try again later.",
        type: "rate_limit_error",
        retry_after: e.retry_after
      }, status: :too_many_requests

    rescue RubyLLM::ServerError => e
      render json: {
        error: "AI service is temporarily unavailable. Please try again.",
        type: "server_error"
      }, status: :service_unavailable

    rescue RubyLLM::Error => e
      render json: {
        error: "An error occurred while processing your request.",
        type: "ai_error",
        details: e.message
      }, status: :bad_request

    rescue => e
      Rails.logger.error "Unexpected error in chat: #{e.message}"
      render json: {
        error: "An unexpected error occurred.",
        type: "internal_error"
      }, status: :internal_server_error
    end
  end
end
```

#### Granular Error Handling with User Feedback
```ruby
class DetailedErrorHandler
  ERROR_MESSAGES = {
    RubyLLM::UnauthorizedError => {
      user_message: "We're having trouble connecting to the AI service. Please contact support.",
      log_level: :error,
      notify_admin: true
    },
    RubyLLM::RateLimitError => {
      user_message: "You're sending messages too quickly. Please wait a moment and try again.",
      log_level: :warn,
      notify_admin: false
    },
    RubyLLM::ModelNotFoundError => {
      user_message: "The requested AI model is not available. Please try a different model.",
      log_level: :error,
      notify_admin: true
    },
    RubyLLM::ValidationError => {
      user_message: "Your message couldn't be processed. Please check your input and try again.",
      log_level: :info,
      notify_admin: false
    },
    RubyLLM::ServerError => {
      user_message: "The AI service is temporarily unavailable. Please try again in a few minutes.",
      log_level: :error,
      notify_admin: true
    },
    RubyLLM::TimeoutError => {
      user_message: "Your request is taking longer than expected. Please try again.",
      log_level: :warn,
      notify_admin: false
    }
  }.freeze

  def self.handle_error(error, context = {})
    error_config = ERROR_MESSAGES[error.class] || default_error_config

    # Log the error
    log_error(error, error_config[:log_level], context)

    # Notify administrators if needed
    notify_admin(error, context) if error_config[:notify_admin]

    # Return user-friendly message
    {
      message: error_config[:user_message],
      type: error.class.name.demodulize.underscore,
      recoverable: recoverable_error?(error),
      retry_after: extract_retry_after(error)
    }
  end

  private

  def self.default_error_config
    {
      user_message: "An unexpected error occurred. Please try again.",
      log_level: :error,
      notify_admin: true
    }
  end

  def self.log_error(error, level, context)
    Rails.logger.send(level, {
      error_class: error.class.name,
      error_message: error.message,
      context: context,
      backtrace: error.backtrace&.first(5)
    }.to_json)
  end

  def self.notify_admin(error, context)
    AdminNotificationJob.perform_later(
      error_class: error.class.name,
      error_message: error.message,
      context: context,
      timestamp: Time.current
    )
  end

  def self.recoverable_error?(error)
    [
      RubyLLM::RateLimitError,
      RubyLLM::ServerError,
      RubyLLM::TimeoutError,
      RubyLLM::NetworkError
    ].include?(error.class)
  end

  def self.extract_retry_after(error)
    case error
    when RubyLLM::RateLimitError
      error.retry_after || 60
    when RubyLLM::ServerError, RubyLLM::TimeoutError
      30
    else
      nil
    end
  end
end
```

### Step 2: Retry Strategies

#### Exponential Backoff with Jitter
```ruby
class IntelligentRetryHandler
  include Async

  def initialize(max_retries: 3, base_delay: 1.0, max_delay: 30.0, jitter: true)
    @max_retries = max_retries
    @base_delay = base_delay
    @max_delay = max_delay
    @jitter = jitter
  end

  def with_retries(context: {}, &block)
    attempt = 0

    begin
      attempt += 1
      result = block.call
      log_success(context, attempt) if attempt > 1
      result

    rescue RubyLLM::Error => e
      if should_retry?(e, attempt)
        delay = calculate_delay(attempt, e)
        log_retry(e, attempt, delay, context)

        # Use async sleep for non-blocking delay
        Async do
          sleep delay
        end.wait

        retry
      else
        log_final_failure(e, attempt, context)
        raise
      end
    end
  end

  private

  def should_retry?(error, attempt)
    return false if attempt >= @max_retries

    retryable_errors = [
      RubyLLM::RateLimitError,
      RubyLLM::ServerError,
      RubyLLM::TimeoutError,
      RubyLLM::NetworkError
    ]

    retryable_errors.include?(error.class)
  end

  def calculate_delay(attempt, error)
    base = case error
    when RubyLLM::RateLimitError
      error.retry_after || @base_delay
    when RubyLLM::ServerError
      @base_delay * 2  # Longer delays for server errors
    else
      @base_delay
    end

    # Exponential backoff
    delay = base * (2 ** (attempt - 1))

    # Apply jitter to prevent thundering herd
    if @jitter
      jitter_range = delay * 0.1
      delay += rand(-jitter_range..jitter_range)
    end

    [delay, @max_delay].min
  end

  def log_retry(error, attempt, delay, context)
    Rails.logger.warn({
      message: "Retrying AI request",
      error_class: error.class.name,
      error_message: error.message,
      attempt: attempt,
      max_retries: @max_retries,
      delay: delay,
      context: context
    }.to_json)
  end

  def log_success(context, attempts)
    Rails.logger.info({
      message: "AI request succeeded after retries",
      attempts: attempts,
      context: context
    }.to_json)
  end

  def log_final_failure(error, attempts, context)
    Rails.logger.error({
      message: "AI request failed after all retries",
      error_class: error.class.name,
      error_message: error.message,
      attempts: attempts,
      context: context
    }.to_json)
  end
end

# Usage example
class ResilientChatService
  def initialize
    @retry_handler = IntelligentRetryHandler.new(
      max_retries: 3,
      base_delay: 1.0,
      max_delay: 30.0
    )
  end

  def send_message(chat, content)
    @retry_handler.with_retries(context: { chat_id: chat.id, content_length: content.length }) do
      chat.ask(content)
    end
  end

  def process_batch(items)
    results = []
    errors = []

    items.each_with_index do |item, index|
      begin
        result = @retry_handler.with_retries(context: { item_index: index }) do
          process_single_item(item)
        end
        results << { index: index, result: result, status: 'success' }

      rescue => e
        errors << { index: index, error: e.message, status: 'failed' }
      end
    end

    { results: results, errors: errors }
  end

  private

  def process_single_item(item)
    RubyLLM.chat.ask("Process this item: #{item}")
  end
end
```

#### Circuit Breaker Pattern
```ruby
class CircuitBreakerRetryHandler
  STATES = [:closed, :open, :half_open].freeze

  def initialize(failure_threshold: 5, recovery_timeout: 60, success_threshold: 3)
    @failure_threshold = failure_threshold
    @recovery_timeout = recovery_timeout
    @success_threshold = success_threshold
    @failure_count = 0
    @success_count = 0
    @last_failure_time = nil
    @state = :closed
    @mutex = Mutex.new
  end

  def call(&block)
    @mutex.synchronize do
      case @state
      when :closed
        execute_with_monitoring(&block)
      when :open
        check_recovery_timeout
        raise CircuitBreakerOpenError, "Circuit breaker is open - too many failures"
      when :half_open
        test_recovery(&block)
      end
    end
  end

  def status
    {
      state: @state,
      failure_count: @failure_count,
      success_count: @success_count,
      last_failure_time: @last_failure_time
    }
  end

  private

  def execute_with_monitoring
    result = yield
    record_success
    result
  rescue RubyLLM::Error => e
    record_failure(e)
    raise
  end

  def record_success
    @failure_count = 0
    @success_count += 1

    if @state == :half_open && @success_count >= @success_threshold
      @state = :closed
      @success_count = 0
      Rails.logger.info "Circuit breaker closed - service recovered"
    end
  end

  def record_failure(error)
    @failure_count += 1
    @last_failure_time = Time.current
    @success_count = 0

    if @failure_count >= @failure_threshold
      @state = :open
      Rails.logger.error "Circuit breaker opened - failure threshold reached (#{@failure_count} failures)"
    end
  end

  def check_recovery_timeout
    if Time.current - @last_failure_time > @recovery_timeout
      @state = :half_open
      @success_count = 0
      Rails.logger.info "Circuit breaker half-open - testing recovery"
    else
      raise CircuitBreakerOpenError, "Circuit breaker is open - recovery timeout not reached"
    end
  end

  def test_recovery
    begin
      result = yield
      record_success
      result
    rescue RubyLLM::Error => e
      @state = :open
      @last_failure_time = Time.current
      Rails.logger.warn "Circuit breaker reopened - recovery test failed"
      raise
    end
  end
end

class CircuitBreakerOpenError < StandardError; end
```

### Step 3: Fallback Mechanisms

#### Service Degradation
```ruby
class GracefulDegradationService
  def initialize
    @primary_chat = RubyLLM.chat(model: 'gpt-4')
    @fallback_chat = RubyLLM.chat(model: 'gpt-3.5-turbo')
    @cache = Rails.cache
  end

  def ask_with_fallback(prompt, cache_key: nil)
    # Try cache first if enabled
    if cache_key
      cached_response = @cache.read(cache_key)
      return cached_response if cached_response
    end

    response = try_primary_service(prompt) ||
               try_fallback_service(prompt) ||
               try_cached_similar_response(prompt) ||
               generate_offline_response(prompt)

    # Cache successful responses
    @cache.write(cache_key, response, expires_in: 1.hour) if cache_key && response

    response
  end

  private

  def try_primary_service(prompt)
    @primary_chat.ask(prompt)
  rescue RubyLLM::Error => e
    Rails.logger.warn "Primary service failed: #{e.message}"
    nil
  end

  def try_fallback_service(prompt)
    @fallback_chat.ask(prompt)
  rescue RubyLLM::Error => e
    Rails.logger.warn "Fallback service failed: #{e.message}"
    nil
  end

  def try_cached_similar_response(prompt)
    # Find semantically similar cached responses
    similar_prompts = find_similar_cached_prompts(prompt)

    similar_prompts.each do |cached_prompt|
      response = @cache.read("ai_response:#{cached_prompt}")
      if response
        Rails.logger.info "Using cached similar response for degraded service"
        return response
      end
    end

    nil
  end

  def generate_offline_response(prompt)
    # Generate a helpful offline response
    Rails.logger.info "All AI services unavailable, generating offline response"

    OpenStruct.new(
      content: "I'm currently unable to process your request due to service issues. " \
               "Please try again later. Your message was: '#{prompt.truncate(100)}'",
      tokens: nil,
      cached: false,
      offline: true
    )
  end

  def find_similar_cached_prompts(prompt)
    # Simple keyword-based similarity for demonstration
    # In production, use embeddings or more sophisticated matching
    keywords = prompt.downcase.split(/\W+/).reject(&:blank?)

    @cache.read("cached_prompts") || []
  end
end
```

#### Provider Fallback Chain
```ruby
class MultiProviderFallbackService
  PROVIDERS = [
    { name: 'openai', model: 'gpt-4', priority: 1 },
    { name: 'anthropic', model: 'claude-3-sonnet', priority: 2 },
    { name: 'openai', model: 'gpt-3.5-turbo', priority: 3 }
  ].freeze

  def initialize
    @provider_health = {}
    @last_health_check = {}
  end

  def ask_with_provider_fallback(prompt, options = {})
    available_providers = get_healthy_providers
    errors = []

    available_providers.each do |provider_config|
      begin
        return execute_with_provider(prompt, provider_config, options)

      rescue RubyLLM::Error => e
        errors << { provider: provider_config[:name], error: e.message }
        mark_provider_unhealthy(provider_config)

        # Continue to next provider unless it's a non-recoverable error
        next unless critical_error?(e)
        break
      end
    end

    # All providers failed
    raise AllProvidersFailedError.new(
      "All AI providers failed",
      errors: errors,
      attempted_providers: available_providers.map { |p| p[:name] }
    )
  end

  private

  def get_healthy_providers
    PROVIDERS
      .select { |p| provider_healthy?(p) }
      .sort_by { |p| p[:priority] }
  end

  def provider_healthy?(provider_config)
    provider_key = provider_config[:name]

    # Check if we have recent health data
    last_check = @last_health_check[provider_key]
    if last_check.nil? || last_check < 5.minutes.ago
      check_provider_health(provider_config)
    end

    @provider_health.fetch(provider_key, true)
  end

  def check_provider_health(provider_config)
    provider_key = provider_config[:name]

    begin
      # Simple health check with a lightweight request
      test_chat = create_chat_for_provider(provider_config)
      test_chat.ask("Hello", timeout: 10)

      @provider_health[provider_key] = true
      Rails.logger.info "Provider #{provider_key} health check passed"

    rescue => e
      @provider_health[provider_key] = false
      Rails.logger.warn "Provider #{provider_key} health check failed: #{e.message}"
    ensure
      @last_health_check[provider_key] = Time.current
    end
  end

  def execute_with_provider(prompt, provider_config, options)
    chat = create_chat_for_provider(provider_config)

    # Apply provider-specific options
    chat = apply_provider_options(chat, provider_config, options)

    response = chat.ask(prompt)

    # Log successful usage
    Rails.logger.info "Successfully used provider: #{provider_config[:name]}"

    response
  end

  def create_chat_for_provider(provider_config)
    case provider_config[:name]
    when 'openai'
      RubyLLM.chat(model: provider_config[:model])
    when 'anthropic'
      RubyLLM.chat(model: provider_config[:model])
    else
      raise "Unknown provider: #{provider_config[:name]}"
    end
  end

  def apply_provider_options(chat, provider_config, options)
    # Apply provider-specific optimizations
    case provider_config[:name]
    when 'openai'
      chat.with_temperature(options[:temperature] || 0.7)
    when 'anthropic'
      chat.with_temperature(options[:temperature] || 0.5)
    end

    chat
  end

  def mark_provider_unhealthy(provider_config)
    provider_key = provider_config[:name]
    @provider_health[provider_key] = false
    @last_health_check[provider_key] = Time.current

    Rails.logger.warn "Marked provider #{provider_key} as unhealthy"
  end

  def critical_error?(error)
    # Don't fallback for authentication or configuration errors
    [
      RubyLLM::UnauthorizedError,
      RubyLLM::ConfigurationError,
      RubyLLM::ValidationError
    ].include?(error.class)
  end
end

class AllProvidersFailedError < RubyLLM::Error
  attr_reader :errors, :attempted_providers

  def initialize(message, errors: [], attempted_providers: [])
    super(message)
    @errors = errors
    @attempted_providers = attempted_providers
  end
end
```

### Step 4: Logging and Monitoring

#### Comprehensive Error Logging
```ruby
class StructuredErrorLogger
  def self.log_ai_error(error, context = {})
    log_data = {
      timestamp: Time.current.iso8601,
      error: {
        class: error.class.name,
        message: error.message,
        backtrace: error.backtrace&.first(10)
      },
      context: context,
      request_id: context[:request_id] || SecureRandom.uuid,
      user_id: context[:user_id],
      chat_id: context[:chat_id],
      model: context[:model],
      prompt_length: context[:prompt]&.length,
      severity: determine_severity(error),
      provider: extract_provider_from_context(context),
      retry_count: context[:retry_count] || 0
    }

    # Add provider-specific error details
    log_data.merge!(extract_provider_error_details(error))

    # Log to Rails logger
    Rails.logger.error(log_data.to_json)

    # Send to external monitoring service
    send_to_monitoring_service(log_data)

    # Create database record for critical errors
    create_error_record(log_data) if critical_error?(error)
  end

  private

  def self.determine_severity(error)
    case error
    when RubyLLM::UnauthorizedError, RubyLLM::ConfigurationError
      'critical'
    when RubyLLM::ServerError, RubyLLM::TimeoutError
      'high'
    when RubyLLM::RateLimitError
      'medium'
    when RubyLLM::ValidationError, RubyLLM::BadRequestError
      'low'
    else
      'unknown'
    end
  end

  def self.extract_provider_from_context(context)
    context[:model]&.split('-')&.first || 'unknown'
  end

  def self.extract_provider_error_details(error)
    details = {}

    case error
    when RubyLLM::RateLimitError
      details[:rate_limit] = {
        retry_after: error.retry_after,
        limit_type: error.limit_type
      }
    when RubyLLM::ServerError
      details[:server_error] = {
        status_code: error.status_code,
        provider_error_code: error.provider_error_code
      }
    end

    details
  end

  def self.send_to_monitoring_service(log_data)
    # Send to external service like DataDog, New Relic, etc.
    MonitoringService.track_error(log_data)
  rescue => e
    Rails.logger.warn "Failed to send error to monitoring service: #{e.message}"
  end

  def self.create_error_record(log_data)
    ErrorLog.create!(
      error_class: log_data[:error][:class],
      error_message: log_data[:error][:message],
      severity: log_data[:severity],
      context: log_data[:context],
      occurred_at: log_data[:timestamp]
    )
  rescue => e
    Rails.logger.warn "Failed to create error record: #{e.message}"
  end

  def self.critical_error?(error)
    [
      RubyLLM::UnauthorizedError,
      RubyLLM::ConfigurationError
    ].include?(error.class)
  end
end
```

#### Real-time Error Monitoring
```ruby
class RealTimeErrorMonitor
  include ActionCable::Broadcasting

  def self.monitor_error(error, context = {})
    error_data = {
      id: SecureRandom.uuid,
      timestamp: Time.current.iso8601,
      error_class: error.class.name,
      error_message: error.message,
      severity: determine_severity(error),
      context: context,
      user_id: context[:user_id],
      chat_id: context[:chat_id]
    }

    # Broadcast to admin dashboard
    broadcast_to_admins(error_data)

    # Send user notification for their errors
    broadcast_to_user(error_data) if context[:user_id]

    # Check for error patterns
    check_error_patterns(error_data)

    # Update metrics
    update_error_metrics(error_data)
  end

  private

  def self.broadcast_to_admins(error_data)
    ActionCable.server.broadcast(
      'admin_errors',
      {
        type: 'new_error',
        error: error_data
      }
    )
  end

  def self.broadcast_to_user(error_data)
    return unless error_data[:user_id]

    ActionCable.server.broadcast(
      "user_#{error_data[:user_id]}_errors",
      {
        type: 'error_notification',
        message: user_friendly_message(error_data),
        recoverable: recoverable_error?(error_data[:error_class])
      }
    )
  end

  def self.check_error_patterns(error_data)
    # Check for spike in errors
    recent_errors = get_recent_errors(5.minutes)

    if recent_errors.count > 10
      AlertService.send_alert(
        type: 'error_spike',
        message: "High error rate detected: #{recent_errors.count} errors in 5 minutes",
        severity: 'high'
      )
    end

    # Check for repeated errors from same user
    user_errors = recent_errors.select { |e| e[:user_id] == error_data[:user_id] }

    if user_errors.count > 5
      AlertService.send_alert(
        type: 'user_error_pattern',
        message: "User #{error_data[:user_id]} experiencing repeated errors",
        severity: 'medium'
      )
    end
  end

  def self.update_error_metrics(error_data)
    Metrics.increment('ai_errors.total', tags: {
      error_class: error_data[:error_class],
      severity: error_data[:severity]
    })

    Metrics.gauge('ai_errors.recent_count',
                 get_recent_errors(1.hour).count)
  end

  def self.get_recent_errors(time_period)
    # Implementation depends on your error storage mechanism
    # This could be Redis, database, or in-memory store
    ErrorCache.get_errors_since(Time.current - time_period)
  end

  def self.user_friendly_message(error_data)
    case error_data[:error_class]
    when 'RubyLLM::RateLimitError'
      "You're sending messages too quickly. Please wait a moment before trying again."
    when 'RubyLLM::ServerError'
      "Our AI service is experiencing issues. We're working to resolve this quickly."
    when 'RubyLLM::TimeoutError'
      "Your request is taking longer than expected. Please try again."
    else
      "We encountered an issue processing your request. Please try again."
    end
  end

  def self.recoverable_error?(error_class)
    %w[
      RubyLLM::RateLimitError
      RubyLLM::ServerError
      RubyLLM::TimeoutError
      RubyLLM::NetworkError
    ].include?(error_class)
  end

  def self.determine_severity(error)
    StructuredErrorLogger.determine_severity(error)
  end
end
```

### Step 5: Provider-Specific Error Handling

#### OpenAI Error Handling
```ruby
class OpenAIErrorHandler
  OPENAI_ERROR_CODES = {
    'insufficient_quota' => RubyLLM::RateLimitError,
    'model_not_found' => RubyLLM::ModelNotFoundError,
    'invalid_api_key' => RubyLLM::UnauthorizedError,
    'context_length_exceeded' => RubyLLM::ValidationError,
    'content_filter' => RubyLLM::ValidationError,
    'server_error' => RubyLLM::ServerError
  }.freeze

  def self.handle_openai_error(error_response)
    error_code = error_response.dig('error', 'code')
    error_message = error_response.dig('error', 'message')
    error_type = error_response.dig('error', 'type')

    # Map OpenAI error codes to RubyLLM errors
    exception_class = OPENAI_ERROR_CODES[error_code] || RubyLLM::Error

    exception = exception_class.new(error_message)

    # Add OpenAI-specific metadata
    exception.define_singleton_method(:openai_error_code) { error_code }
    exception.define_singleton_method(:openai_error_type) { error_type }

    # Handle specific error types
    case error_code
    when 'insufficient_quota'
      handle_quota_exceeded(exception, error_response)
    when 'rate_limit_exceeded'
      handle_rate_limit(exception, error_response)
    when 'context_length_exceeded'
      handle_context_length(exception, error_response)
    end

    exception
  end

  private

  def self.handle_quota_exceeded(exception, error_response)
    # Extract quota information if available
    quota_info = error_response.dig('error', 'quota_info')

    exception.define_singleton_method(:quota_exceeded?) { true }
    exception.define_singleton_method(:quota_info) { quota_info }

    # Log quota issue for billing alerts
    Rails.logger.error "OpenAI quota exceeded: #{quota_info}"
  end

  def self.handle_rate_limit(exception, error_response)
    # Extract retry information
    retry_after = error_response.dig('error', 'retry_after')

    exception.define_singleton_method(:retry_after) { retry_after }

    Rails.logger.warn "OpenAI rate limit hit, retry after: #{retry_after}s"
  end

  def self.handle_context_length(exception, error_response)
    # Extract context length information
    max_tokens = error_response.dig('error', 'max_tokens')
    current_tokens = error_response.dig('error', 'current_tokens')

    exception.define_singleton_method(:max_tokens) { max_tokens }
    exception.define_singleton_method(:current_tokens) { current_tokens }

    Rails.logger.info "OpenAI context length exceeded: #{current_tokens}/#{max_tokens} tokens"
  end
end
```

#### Anthropic Error Handling
```ruby
class AnthropicErrorHandler
  ANTHROPIC_ERROR_TYPES = {
    'authentication_error' => RubyLLM::UnauthorizedError,
    'permission_error' => RubyLLM::ForbiddenError,
    'not_found_error' => RubyLLM::NotFoundError,
    'request_too_large' => RubyLLM::ValidationError,
    'rate_limit_error' => RubyLLM::RateLimitError,
    'api_error' => RubyLLM::ServerError,
    'overloaded_error' => RubyLLM::ServerError
  }.freeze

  def self.handle_anthropic_error(error_response)
    error_type = error_response.dig('error', 'type')
    error_message = error_response.dig('error', 'message')

    exception_class = ANTHROPIC_ERROR_TYPES[error_type] || RubyLLM::Error
    exception = exception_class.new(error_message)

    # Add Anthropic-specific metadata
    exception.define_singleton_method(:anthropic_error_type) { error_type }

    # Handle specific error types
    case error_type
    when 'rate_limit_error'
      handle_anthropic_rate_limit(exception, error_response)
    when 'overloaded_error'
      handle_anthropic_overload(exception, error_response)
    when 'request_too_large'
      handle_anthropic_size_limit(exception, error_response)
    end

    exception
  end

  private

  def self.handle_anthropic_rate_limit(exception, error_response)
    # Anthropic rate limits often don't provide explicit retry times
    # Use conservative defaults
    exception.define_singleton_method(:retry_after) { 60 }

    Rails.logger.warn "Anthropic rate limit hit"
  end

  def self.handle_anthropic_overload(exception, error_response)
    # Server overload - longer retry time recommended
    exception.define_singleton_method(:retry_after) { 120 }

    Rails.logger.error "Anthropic API overloaded"
  end

  def self.handle_anthropic_size_limit(exception, error_response)
    # Request too large
    Rails.logger.warn "Anthropic request size exceeded"
  end
end
```

## Recovery and Graceful Degradation Strategies

### Automatic Recovery Mechanisms
```ruby
class AutoRecoveryService
  def initialize
    @recovery_strategies = {
      RubyLLM::RateLimitError => :rate_limit_recovery,
      RubyLLM::ServerError => :server_error_recovery,
      RubyLLM::TimeoutError => :timeout_recovery,
      RubyLLM::ValidationError => :validation_error_recovery
    }
  end

  def recover_from_error(error, original_request)
    strategy = @recovery_strategies[error.class]

    if strategy
      send(strategy, error, original_request)
    else
      default_recovery(error, original_request)
    end
  end

  private

  def rate_limit_recovery(error, original_request)
    # Implement exponential backoff
    retry_after = error.retry_after || 60

    Rails.logger.info "Rate limit recovery: waiting #{retry_after}s"

    # Schedule retry
    RetryJob.set(wait: retry_after.seconds)
              .perform_later(original_request)

    {
      status: 'queued_for_retry',
      retry_after: retry_after,
      message: "Request queued for retry due to rate limiting"
    }
  end

  def server_error_recovery(error, original_request)
    # Try alternative model or provider
    fallback_request = original_request.dup
    fallback_request[:model] = select_fallback_model(original_request[:model])

    begin
      result = execute_request(fallback_request)
      Rails.logger.info "Server error recovery successful with fallback model"
      result
    rescue => e
      Rails.logger.error "Fallback model also failed: #{e.message}"
      queue_for_later_retry(original_request)
    end
  end

  def timeout_recovery(error, original_request)
    # Try with reduced complexity or shorter prompt
    simplified_request = simplify_request(original_request)

    begin
      result = execute_request(simplified_request)
      Rails.logger.info "Timeout recovery successful with simplified request"
      result
    rescue => e
      Rails.logger.error "Simplified request also failed: #{e.message}"
      return_cached_response(original_request) || default_response
    end
  end

  def validation_error_recovery(error, original_request)
    # Try to fix common validation issues
    fixed_request = fix_validation_issues(original_request, error)

    if fixed_request
      begin
        result = execute_request(fixed_request)
        Rails.logger.info "Validation error recovery successful"
        result
      rescue => e
        Rails.logger.error "Fixed request still failed: #{e.message}"
        validation_error_response(error)
      end
    else
      validation_error_response(error)
    end
  end

  def default_recovery(error, original_request)
    Rails.logger.info "No specific recovery strategy for #{error.class}"

    # Try basic retry with simplified request
    simplified_request = simplify_request(original_request)

    begin
      execute_request(simplified_request)
    rescue => e
      return_cached_response(original_request) || default_response
    end
  end

  def select_fallback_model(original_model)
    fallback_map = {
      'gpt-4' => 'gpt-3.5-turbo',
      'claude-3-opus' => 'claude-3-sonnet',
      'claude-3-sonnet' => 'claude-3-haiku'
    }

    fallback_map[original_model] || 'gpt-3.5-turbo'
  end

  def simplify_request(request)
    simplified = request.dup

    # Reduce prompt length if too long
    if simplified[:prompt].length > 2000
      simplified[:prompt] = simplified[:prompt].truncate(2000)
    end

    # Use simpler model
    simplified[:model] = select_fallback_model(simplified[:model])

    # Reduce temperature for more predictable results
    simplified[:temperature] = 0.3

    simplified
  end

  def fix_validation_issues(request, error)
    fixed_request = request.dup

    case error.message
    when /context length/i
      # Truncate prompt to fit context window
      max_length = extract_max_length(error) || 2000
      fixed_request[:prompt] = request[:prompt].truncate(max_length)

    when /invalid characters/i
      # Clean invalid characters
      fixed_request[:prompt] = request[:prompt].encode('UTF-8', invalid: :replace, undef: :replace)

    when /file size/i
      # Remove or compress large attachments
      fixed_request[:attachments] = compress_attachments(request[:attachments])

    else
      return nil  # Can't fix this validation error
    end

    fixed_request
  end

  def execute_request(request)
    # Implementation depends on your request format
    chat = RubyLLM.chat(model: request[:model])
    chat.with_temperature(request[:temperature] || 0.7)
        .ask(request[:prompt])
  end

  def return_cached_response(request)
    # Look for similar cached responses
    cache_key = generate_cache_key(request)
    Rails.cache.read(cache_key)
  end

  def default_response
    OpenStruct.new(
      content: "I'm temporarily unable to process your request. Please try again later.",
      cached: false,
      fallback: true
    )
  end

  def queue_for_later_retry(request)
    RetryJob.set(wait: 5.minutes).perform_later(request)

    {
      status: 'queued_for_retry',
      message: "Request queued for retry in 5 minutes"
    }
  end

  def validation_error_response(error)
    {
      status: 'validation_error',
      message: "Unable to process request due to validation issues: #{error.message}",
      error: error.message
    }
  end
end
```

This comprehensive error handling documentation provides robust strategies for dealing with all types of errors that can occur when using RubyLLM, including retry mechanisms, fallback strategies, monitoring, and graceful recovery patterns for production applications.