# RubyLLM Async Operations Documentation

## Version Information
- Documentation source: https://rubyllm.com/async/
- Related sources: https://rubyllm.com/rails/, https://rubyllm.com/streaming/
- Fetched: 2025-10-05

## Key Concepts

### Async Ruby Fundamentals
- **Fiber-based Concurrency**: Uses fibers instead of threads for lightweight, efficient concurrency
- **I/O Optimization**: Automatically handles non-blocking network operations
- **Resource Efficiency**: Thousands of concurrent operations can share just a few connections
- **Context Switching**: Automatic context switching during I/O operations without blocking

### Why Async for LLM Operations
LLM operations are inherently I/O-bound, making them perfect candidates for async processing:
- **Network Latency**: API calls to LLM providers involve network round trips
- **Response Streaming**: Real-time streaming requires non-blocking I/O
- **Batch Processing**: Multiple concurrent requests can be processed efficiently
- **Rate Limiting**: Natural backpressure handling through semaphores

### Core Async Patterns
```ruby
# Basic async operation
Async do
  response = RubyLLM.chat.ask("What is Ruby?")
  puts response.content
end

# Concurrent operations
Async do
  questions = ["What is Ruby?", "What is Rails?", "What is async?"]

  tasks = questions.map do |question|
    Async do
      response = RubyLLM.chat.ask(question)
      { question: question, answer: response.content }
    end
  end

  results = tasks.map(&:wait)
  puts results
end
```

## Implementation Guide

### Step 1: ActiveJob Integration Setup

#### Configuring Async Job Adapter

```ruby
# config/application.rb
class Application < Rails::Application
  # Use async adapter for lightweight AI operations
  config.active_job.queue_adapter = :async_job

  # Alternative: Mixed adapter configuration
  # config.active_job.queue_adapter = :sidekiq  # Default
  # Use async_job specifically for AI-related jobs
end

# config/environments/development.rb
Rails.application.configure do
  # Enable async job adapter in development
  config.active_job.queue_adapter = :async_job

  # Configure async job settings
  config.active_job.async_job = {
    max_threads: 4,
    max_queue_size: 100
  }
end

# config/environments/production.rb
Rails.application.configure do
  # Production async configuration
  config.active_job.queue_adapter = :sidekiq  # Primary adapter

  # Configure specific queues for async processing
  config.active_job.queue_name_prefix = "myapp_#{Rails.env}"
  config.active_job.queue_name_delimiter = '_'
end
```

#### Mixed Queue Adapter Strategy

```ruby
# Use different adapters for different job types
class ApplicationJob < ActiveJob::Base
  # Default to Sidekiq for heavy operations
  queue_as :default
end

class AiResponseJob < ApplicationJob
  # Use async adapter for AI operations
  queue_adapter :async_job
  queue_as :ai_responses

  def perform(chat_id, message_content)
    chat = Chat.find(chat_id)

    Async do
      response = chat.ask(message_content) do |chunk|
        broadcast_chunk(chat, chunk)
      end

      # Update chat with final response
      chat.messages.create!(
        role: 'assistant',
        content: response.content,
        metadata: { tokens: response.tokens }
      )
    end
  end

  private

  def broadcast_chunk(chat, chunk)
    ActionCable.server.broadcast(
      "chat_#{chat.id}",
      {
        type: 'chunk',
        content: chunk.content,
        finished: chunk.finished?
      }
    )
  end
end

class BatchProcessingJob < ApplicationJob
  # Use Sidekiq for heavy, persistent operations
  queue_adapter :sidekiq
  queue_as :batch_processing

  def perform(batch_id)
    # Heavy computational work that needs persistence
  end
end
```

### Step 2: Background Processing Setup

#### Fiber-based Server Configuration (Falcon)

```ruby
# Gemfile
gem 'falcon', '~> 0.42'
gem 'async-job', '~> 0.1'

# config/falcon.rb
#!/usr/bin/env falcon serve

load :rack, :self_signed_tls, :supervisor

hostname = File.basename(__dir__)
port = ENV.fetch('PORT', 3000).to_i

rack hostname do
  cache false

  # Enable async/await support
  protocol :http2
  endpoint Async::HTTP::Endpoint.parse("https://#{hostname}:#{port}")

  # Async-optimized middleware
  use Async::HTTP::Middleware::Decompress
  use Async::HTTP::Middleware::Redirect
end

supervisor
```

#### Puma with Redis Backend

```ruby
# Gemfile
gem 'redis', '~> 5.0'
gem 'async-redis', '~> 0.8'

# config/initializers/async_redis.rb
Async::Redis.configure do |config|
  config.url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  config.pool_size = 20
  config.timeout = 30
end

# Background job processor with Redis
class AsyncJobProcessor
  include Async

  def initialize(redis_url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    @redis = Async::Redis::Client.new(url: redis_url)
  end

  def start
    Async do
      loop do
        job_data = @redis.call('BLPOP', 'ai_jobs', 30)

        if job_data
          process_job(JSON.parse(job_data[1]))
        end
      rescue => e
        Rails.logger.error "Job processing error: #{e.message}"
        sleep 1
      end
    end
  end

  private

  def process_job(job_data)
    Async do
      case job_data['type']
      when 'ai_response'
        process_ai_response(job_data)
      when 'batch_analysis'
        process_batch_analysis(job_data)
      end
    end
  end

  def process_ai_response(job_data)
    chat = Chat.find(job_data['chat_id'])

    chat.ask(job_data['prompt']) do |chunk|
      # Broadcast via ActionCable
      ActionCable.server.broadcast(
        "chat_#{chat.id}",
        { type: 'chunk', content: chunk.content }
      )
    end
  end

  def process_batch_analysis(job_data)
    documents = Document.where(id: job_data['document_ids'])

    # Process documents concurrently
    tasks = documents.map do |doc|
      Async do
        result = RubyLLM.chat.ask("Analyze this document: #{doc.content}")
        doc.update!(analysis: result.content)
        result
      end
    end

    # Wait for all analyses to complete
    results = tasks.map(&:wait)

    # Notify completion
    NotificationMailer.batch_analysis_complete(
      job_data['user_id'],
      results.size
    ).deliver_now
  end
end
```

#### Procfile Configuration

```ruby
# Procfile.dev
web: bundle exec falcon serve --config config/falcon.rb
ai_processor: bundle exec rails runner "AsyncJobProcessor.new.start"
worker: bundle exec sidekiq -C config/sidekiq.yml

# Procfile (production)
web: bundle exec puma -C config/puma.rb
ai_processor: bundle exec rails runner "AsyncJobProcessor.new.start"
worker: bundle exec sidekiq -C config/sidekiq.yml
```

### Step 3: Async Callbacks Implementation

```ruby
class AsyncChatService
  include Async::Notification

  def initialize(chat)
    @chat = chat
    @callbacks = {}
  end

  # Register callback handlers
  def on_chunk(&block)
    @callbacks[:chunk] = block
  end

  def on_complete(&block)
    @callbacks[:complete] = block
  end

  def on_error(&block)
    @callbacks[:error] = block
  end

  def on_token_usage(&block)
    @callbacks[:token_usage] = block
  end

  # Async message processing
  def send_message_async(content, attachments: [])
    Async do
      begin
        # Create user message
        user_message = create_user_message(content, attachments)

        # Track token usage
        initial_tokens = @chat.total_tokens

        # Process AI response with streaming
        response = @chat.ask(content) do |chunk|
          handle_chunk(chunk)
        end

        # Calculate token usage
        tokens_used = @chat.total_tokens - initial_tokens
        handle_token_usage(tokens_used)

        # Handle completion
        handle_completion(response)

        response
      rescue => e
        handle_error(e)
        raise
      end
    end
  end

  # Batch processing with concurrency control
  def process_batch_async(prompts, max_concurrency: 5)
    Async do |task|
      semaphore = Async::Semaphore.new(max_concurrency)

      tasks = prompts.map do |prompt|
        task.async do
          semaphore.acquire do
            response = @chat.ask(prompt)
            { prompt: prompt, response: response.content }
          end
        end
      end

      # Wait for all tasks to complete
      results = tasks.map(&:wait)

      # Notify batch completion
      handle_batch_completion(results)

      results
    end
  end

  private

  def create_user_message(content, attachments)
    message = @chat.messages.create!(
      content: content,
      role: 'user'
    )

    if attachments.any?
      message.files.attach(attachments)
    end

    message
  end

  def handle_chunk(chunk)
    return unless @callbacks[:chunk]

    Async do
      @callbacks[:chunk].call(chunk)
    end
  end

  def handle_completion(response)
    return unless @callbacks[:complete]

    Async do
      @callbacks[:complete].call(response)
    end
  end

  def handle_error(error)
    return unless @callbacks[:error]

    Async do
      @callbacks[:error].call(error)
    end
  end

  def handle_token_usage(tokens)
    return unless @callbacks[:token_usage]

    Async do
      @callbacks[:token_usage].call(tokens)
    end
  end

  def handle_batch_completion(results)
    # Log batch completion
    Rails.logger.info "Batch processing completed: #{results.size} items processed"

    # Update metrics
    Metrics.increment('ai.batch.completed', tags: {
      batch_size: results.size,
      chat_id: @chat.id
    })
  end
end
```

### Step 4: Queue Management Strategies

#### Priority Queue Implementation

```ruby
class PriorityAsyncQueue
  include Async

  PRIORITIES = {
    urgent: 0,
    high: 1,
    normal: 2,
    low: 3,
    batch: 4
  }.freeze

  def initialize
    @queues = PRIORITIES.keys.map { |priority|
      [priority, Async::Queue.new]
    }.to_h
    @running = false
  end

  def start
    return if @running
    @running = true

    Async do
      PRIORITIES.each do |priority, _|
        start_worker(priority)
      end
    end
  end

  def enqueue(job, priority: :normal)
    raise ArgumentError, "Invalid priority" unless PRIORITIES.key?(priority)

    @queues[priority].enqueue(job)
  end

  def stop
    @running = false
    @queues.each_value(&:close)
  end

  private

  def start_worker(priority)
    Async do
      queue = @queues[priority]

      while @running
        begin
          # Use timeout to allow checking @running flag
          job = queue.dequeue(timeout: 1.0)

          if job
            process_job(job, priority)
          end
        rescue Async::TimeoutError
          # Continue checking for jobs
        rescue => e
          Rails.logger.error "Worker error for #{priority}: #{e.message}"
          sleep 1
        end
      end
    end
  end

  def process_job(job, priority)
    Async do
      start_time = Time.current

      case job[:type]
      when 'ai_response'
        process_ai_response(job)
      when 'batch_analysis'
        process_batch_analysis(job)
      when 'file_processing'
        process_file_upload(job)
      end

      duration = Time.current - start_time

      # Log job completion
      Rails.logger.info "Job completed",
        type: job[:type],
        priority: priority,
        duration: duration

      # Update metrics
      Metrics.timing('async_job.duration', duration, tags: {
        type: job[:type],
        priority: priority
      })
    end
  end

  def process_ai_response(job)
    chat = Chat.find(job[:chat_id])

    chat.ask(job[:prompt]) do |chunk|
      ActionCable.server.broadcast(
        "chat_#{chat.id}",
        { type: 'chunk', content: chunk.content }
      )
    end
  end

  def process_batch_analysis(job)
    # Process multiple documents concurrently
    documents = Document.where(id: job[:document_ids])

    tasks = documents.map do |doc|
      Async do
        analysis = RubyLLM.chat.ask("Analyze: #{doc.content}")
        doc.update!(analysis: analysis.content)
      end
    end

    tasks.map(&:wait)
  end

  def process_file_upload(job)
    file = ActiveStorage::Blob.find(job[:blob_id])

    case file.content_type
    when /\Aimage/
      analyze_image(file)
    when /\Aaudio/
      transcribe_audio(file)
    when 'application/pdf'
      extract_pdf_content(file)
    end
  end

  def analyze_image(file)
    # Process image with vision model
    result = RubyLLM.chat(model: 'gpt-4-vision-preview')
                    .ask("Describe this image", attachments: [file])

    # Store analysis result
    file.metadata[:ai_description] = result.content
    file.save!
  end

  def transcribe_audio(file)
    # Transcribe audio file
    result = RubyLLM.chat(model: 'whisper-1')
                    .transcribe(file)

    # Store transcription
    file.metadata[:transcription] = result.text
    file.save!
  end

  def extract_pdf_content(file)
    # Extract and analyze PDF content
    content = PDFReader.new(file.download).text
    summary = RubyLLM.chat.ask("Summarize this document: #{content}")

    file.metadata[:summary] = summary.content
    file.save!
  end
end
```

#### Rate Limiting with Semaphores

```ruby
class RateLimitedAsyncProcessor
  include Async

  def initialize(max_concurrent: 10, requests_per_minute: 60)
    @semaphore = Async::Semaphore.new(max_concurrent)
    @rate_limiter = RateLimiter.new(requests_per_minute)
  end

  def process_requests(requests)
    Async do |task|
      tasks = requests.map do |request|
        task.async do
          @semaphore.acquire do
            @rate_limiter.wait_if_needed

            process_single_request(request)
          end
        end
      end

      tasks.map(&:wait)
    end
  end

  private

  def process_single_request(request)
    start_time = Time.current

    begin
      response = RubyLLM.chat.ask(request[:prompt])

      {
        request_id: request[:id],
        response: response.content,
        tokens: response.tokens,
        duration: Time.current - start_time,
        status: 'success'
      }
    rescue => e
      {
        request_id: request[:id],
        error: e.message,
        duration: Time.current - start_time,
        status: 'error'
      }
    end
  end
end

class RateLimiter
  def initialize(requests_per_minute)
    @requests_per_minute = requests_per_minute
    @request_times = []
    @mutex = Mutex.new
  end

  def wait_if_needed
    @mutex.synchronize do
      now = Time.current

      # Remove requests older than 1 minute
      @request_times.reject! { |time| time < now - 60 }

      # Check if we're at the limit
      if @request_times.size >= @requests_per_minute
        sleep_time = 60 - (now - @request_times.first)
        sleep(sleep_time) if sleep_time > 0

        # Clean up old requests again
        @request_times.reject! { |time| time < Time.current - 60 }
      end

      # Record this request
      @request_times << Time.current
    end
  end
end
```

### Step 5: Sidekiq and GoodJob Integration

#### Sidekiq Integration

```ruby
# Gemfile
gem 'sidekiq', '~> 7.0'
gem 'sidekiq-web', '~> 7.0'

# config/sidekiq.yml
:queues:
  - critical
  - ai_responses
  - batch_processing
  - default
  - low_priority

:max_retries: 3
:dead_timeout: 604800  # 1 week

# Async-aware Sidekiq job
class AsyncAiResponseJob < ApplicationJob
  include Sidekiq::Job

  sidekiq_options queue: 'ai_responses', retry: 3

  def perform(chat_id, message_content)
    chat = Chat.find(chat_id)

    # Use Async within Sidekiq for concurrent operations
    Async do
      response = chat.ask(message_content) do |chunk|
        # Real-time broadcasting
        ActionCable.server.broadcast(
          "chat_#{chat.id}",
          { type: 'chunk', content: chunk.content }
        )
      end

      # Store final response
      chat.messages.create!(
        role: 'assistant',
        content: response.content,
        metadata: {
          tokens: response.tokens,
          model: response.model
        }
      )
    end
  rescue => e
    Rails.logger.error "AsyncAiResponseJob failed: #{e.message}"

    # Create error message for user
    chat.messages.create!(
      role: 'system',
      content: "I encountered an error processing your message. Please try again.",
      metadata: { error: e.class.name }
    )

    raise
  end
end

# Batch processing with Sidekiq
class AsyncBatchProcessingJob < ApplicationJob
  include Sidekiq::Job

  sidekiq_options queue: 'batch_processing', retry: 2

  def perform(batch_id, document_ids)
    batch = ProcessingBatch.find(batch_id)
    documents = Document.where(id: document_ids)

    Async do
      # Process documents with controlled concurrency
      semaphore = Async::Semaphore.new(5)

      tasks = documents.map do |doc|
        Async do
          semaphore.acquire do
            process_document(doc)
          end
        end
      end

      results = tasks.map(&:wait)

      # Update batch status
      batch.update!(
        status: 'completed',
        results_count: results.size,
        completed_at: Time.current
      )

      # Notify user
      BatchCompletionMailer.notify(batch.user, batch).deliver_now
    end
  end

  private

  def process_document(document)
    analysis = RubyLLM.chat.ask(
      "Analyze this document and extract key insights: #{document.content}"
    )

    document.update!(
      analysis: analysis.content,
      processed_at: Time.current
    )
  end
end
```

#### GoodJob Integration

```ruby
# Gemfile
gem 'good_job', '~> 3.0'

# config/application.rb
class Application < Rails::Application
  config.active_job.queue_adapter = :good_job
end

# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :async
  config.good_job.max_threads = 5
  config.good_job.poll_interval = 30

  # Configure queues
  config.good_job.queues = {
    'ai_responses' => 3,
    'batch_processing' => 2,
    'default' => 2
  }

  # Dashboard authentication
  config.good_job.dashboard_default_locale = :en
end

# Async-optimized GoodJob worker
class AsyncGoodJobWorker < GoodJob::Job
  def perform(operation_type, **kwargs)
    case operation_type
    when 'ai_chat'
      handle_ai_chat(**kwargs)
    when 'batch_analysis'
      handle_batch_analysis(**kwargs)
    when 'file_processing'
      handle_file_processing(**kwargs)
    end
  end

  private

  def handle_ai_chat(chat_id:, prompt:)
    chat = Chat.find(chat_id)

    Async do
      response = chat.ask(prompt) do |chunk|
        broadcast_chunk(chat, chunk)
      end

      update_chat_statistics(chat, response)
    end
  end

  def handle_batch_analysis(document_ids:, analysis_type:)
    documents = Document.where(id: document_ids)

    Async do
      tasks = documents.map do |doc|
        Async do
          analyze_document(doc, analysis_type)
        end
      end

      results = tasks.map(&:wait)

      Rails.logger.info "Batch analysis completed: #{results.size} documents"
    end
  end

  def handle_file_processing(file_id:, processing_type:)
    file = ActiveStorage::Blob.find(file_id)

    Async do
      case processing_type
      when 'image_analysis'
        analyze_image_async(file)
      when 'audio_transcription'
        transcribe_audio_async(file)
      when 'document_extraction'
        extract_document_content_async(file)
      end
    end
  end

  def broadcast_chunk(chat, chunk)
    ActionCable.server.broadcast(
      "chat_#{chat.id}",
      {
        type: 'streaming_chunk',
        content: chunk.content,
        finished: chunk.finished?
      }
    )
  end

  def analyze_document(document, analysis_type)
    prompt = case analysis_type
    when 'summary'
      "Provide a concise summary of this document: #{document.content}"
    when 'key_points'
      "Extract the key points from this document: #{document.content}"
    when 'sentiment'
      "Analyze the sentiment of this document: #{document.content}"
    end

    analysis = RubyLLM.chat.ask(prompt)

    document.update!(
      "#{analysis_type}_analysis": analysis.content,
      analyzed_at: Time.current
    )
  end
end
```

## Performance Considerations

### Memory Management
```ruby
class MemoryEfficientAsyncProcessor
  include Async

  def initialize(max_memory_mb: 1000)
    @max_memory_mb = max_memory_mb
    @memory_monitor = MemoryMonitor.new
  end

  def process_large_batch(items)
    Async do
      chunks = items.each_slice(chunk_size).to_a

      chunks.each do |chunk|
        # Check memory usage before processing
        if @memory_monitor.usage_mb > @max_memory_mb
          GC.start
          sleep 0.1  # Allow GC to complete
        end

        process_chunk_async(chunk)
      end
    end
  end

  private

  def chunk_size
    # Adjust chunk size based on available memory
    available_memory = @max_memory_mb - @memory_monitor.usage_mb
    [available_memory / 10, 5].max.to_i
  end

  def process_chunk_async(chunk)
    Async do
      tasks = chunk.map do |item|
        Async do
          process_item(item)
        end
      end

      tasks.map(&:wait)
    end
  end
end

class MemoryMonitor
  def usage_mb
    `ps -o rss= -p #{Process.pid}`.to_i / 1024
  end
end
```

### Connection Pooling
```ruby
# config/initializers/async_http.rb
Async::HTTP::Client.configure do |config|
  config.timeout = 60
  config.retries = 3
  config.pool_limit = 100
end

# Custom connection pool for LLM providers
class LLMConnectionPool
  include Async

  def initialize(max_connections: 20)
    @pool = Async::Pool.new(max_connections) do
      create_connection
    end
  end

  def with_connection(&block)
    @pool.acquire do |connection|
      block.call(connection)
    end
  end

  private

  def create_connection
    # Create optimized HTTP connection for LLM APIs
    Async::HTTP::Client.new(
      timeout: 120,
      retries: 2,
      pool_limit: 10
    )
  end
end
```

### Monitoring and Metrics
```ruby
class AsyncMetricsCollector
  include Async

  def initialize
    @metrics = {}
    @mutex = Mutex.new
  end

  def start_monitoring
    Async do
      every(30.seconds) do
        collect_metrics
      end
    end
  end

  def record_operation(operation_type, duration, success)
    @mutex.synchronize do
      @metrics[operation_type] ||= {
        count: 0,
        total_duration: 0,
        success_count: 0,
        error_count: 0
      }

      metric = @metrics[operation_type]
      metric[:count] += 1
      metric[:total_duration] += duration

      if success
        metric[:success_count] += 1
      else
        metric[:error_count] += 1
      end
    end
  end

  def get_metrics
    @mutex.synchronize do
      @metrics.transform_values do |metric|
        metric.merge(
          average_duration: metric[:total_duration] / metric[:count],
          success_rate: metric[:success_count].to_f / metric[:count],
          error_rate: metric[:error_count].to_f / metric[:count]
        )
      end
    end
  end

  private

  def collect_metrics
    # Send metrics to monitoring service
    metrics = get_metrics

    metrics.each do |operation_type, stats|
      Metrics.gauge('async_operation.average_duration',
                   stats[:average_duration],
                   tags: { operation: operation_type })

      Metrics.gauge('async_operation.success_rate',
                   stats[:success_rate],
                   tags: { operation: operation_type })

      Metrics.gauge('async_operation.error_rate',
                   stats[:error_rate],
                   tags: { operation: operation_type })
    end
  end

  def every(interval)
    loop do
      yield
      sleep interval
    end
  end
end
```

## Best Practices

### 1. Error Handling and Resilience
```ruby
class ResilientAsyncProcessor
  include Async

  def process_with_retry(operation, max_retries: 3)
    Async do
      retries = 0

      begin
        operation.call
      rescue => e
        retries += 1

        if retries <= max_retries
          delay = exponential_backoff(retries)
          Rails.logger.warn "Retry #{retries}/#{max_retries} after #{delay}s: #{e.message}"

          sleep delay
          retry
        else
          Rails.logger.error "Operation failed after #{max_retries} retries: #{e.message}"
          raise
        end
      end
    end
  end

  private

  def exponential_backoff(attempt)
    [2 ** attempt, 30].min  # Max 30 seconds
  end
end
```

### 2. Resource Management
```ruby
class ResourceManagedAsyncWorker
  include Async

  def initialize
    @semaphore = Async::Semaphore.new(concurrent_limit)
    @circuit_breaker = CircuitBreaker.new
  end

  def process_safely(operation)
    Async do
      @semaphore.acquire do
        @circuit_breaker.call do
          operation.call
        end
      end
    end
  end

  private

  def concurrent_limit
    # Adjust based on system resources
    ENV.fetch('MAX_CONCURRENT_OPERATIONS', 10).to_i
  end
end

class CircuitBreaker
  def initialize(failure_threshold: 5, recovery_timeout: 60)
    @failure_threshold = failure_threshold
    @recovery_timeout = recovery_timeout
    @failure_count = 0
    @last_failure_time = nil
    @state = :closed  # :closed, :open, :half_open
  end

  def call
    case @state
    when :closed
      execute_with_monitoring { yield }
    when :open
      check_recovery_timeout
      raise CircuitBreakerOpenError, "Circuit breaker is open"
    when :half_open
      test_recovery { yield }
    end
  end

  private

  def execute_with_monitoring
    result = yield
    reset_failure_count
    result
  rescue => e
    record_failure
    raise
  end

  def record_failure
    @failure_count += 1
    @last_failure_time = Time.current

    if @failure_count >= @failure_threshold
      @state = :open
      Rails.logger.warn "Circuit breaker opened after #{@failure_count} failures"
    end
  end

  def reset_failure_count
    @failure_count = 0
    @state = :closed
  end

  def check_recovery_timeout
    if Time.current - @last_failure_time > @recovery_timeout
      @state = :half_open
    end
  end

  def test_recovery
    result = yield
    reset_failure_count
    Rails.logger.info "Circuit breaker recovered"
    result
  rescue => e
    @state = :open
    @last_failure_time = Time.current
    raise
  end
end
```

This comprehensive async operations documentation provides everything needed to implement efficient, scalable async processing with RubyLLM, including ActiveJob integration, background processing, queue management, and production-ready patterns for handling concurrent AI operations.