# RubyLLM Tools - Execution Flow

## Overview

Understanding tool execution flow is crucial for building robust AI applications. This guide covers sequential vs parallel execution patterns, error handling strategies, retry logic, and advanced execution control mechanisms.

## Basic Execution Flow

When an AI model decides to use tools, the execution follows this pattern:

1. **Tool Selection** - AI analyzes user input and determines which tool(s) to use
2. **Parameter Extraction** - AI extracts parameters from user input for tool calls
3. **Tool Invocation** - RubyLLM calls the tool's `execute` method
4. **Result Processing** - Tool returns result (string, hash, or Content object)
5. **AI Response** - AI uses tool results to generate final response to user

```ruby
class ExecutionFlowDemo < RubyLLM::Tool
  description "Demonstrates basic execution flow"

  param :step, desc: "Which step to demonstrate"

  def execute(step:)
    Rails.logger.info("Tool execution started for step: #{step}")

    result = case step
    when "data_fetch"
      fetch_data_step
    when "processing"
      process_data_step
    when "output"
      generate_output_step
    else
      { error: "Unknown step: #{step}" }
    end

    Rails.logger.info("Tool execution completed for step: #{step}")
    result
  end

  private

  def fetch_data_step
    # Simulate data fetching
    { status: "Data fetched", records: 150, timestamp: Time.current }
  end

  def process_data_step
    # Simulate processing
    { status: "Data processed", processed_count: 150, duration: "2.3s" }
  end

  def generate_output_step
    # Simulate output generation
    { status: "Output generated", file_path: "/tmp/report.pdf" }
  end
end
```

## Sequential Tool Execution

By default, tools execute sequentially when multiple tools are needed:

```ruby
# Chat example where AI uses multiple tools in sequence
chat = RubyLLM.chat(model: 'gpt-4')
         .with_tool(DataFetcher)
         .with_tool(DataProcessor)
         .with_tool(ReportGenerator)

# User query that triggers multiple tools
response = chat.ask("Generate a quarterly sales report with charts")

# Execution flow:
# 1. AI calls DataFetcher to get sales data
# 2. AI calls DataProcessor to analyze the data
# 3. AI calls ReportGenerator to create the final report
# 4. AI provides final response with report summary
```

### Designing Tools for Sequential Flow

```ruby
class DataFetcher < RubyLLM::Tool
  description "Fetches sales data for specified period"

  param :period, desc: "Time period: quarterly, monthly, yearly"
  param :year, desc: "Year to fetch data for", type: :integer

  def execute(period:, year:)
    # Fetch raw data
    data = SalesRecord.where(
      created_at: date_range_for_period(period, year)
    ).includes(:customer, :products)

    {
      period: period,
      year: year,
      total_records: data.count,
      total_revenue: data.sum(:amount),
      data_summary: summarize_data(data),
      message: "Fetched #{data.count} sales records for #{period} #{year}"
    }
  end

  private

  def date_range_for_period(period, year)
    case period
    when "quarterly"
      quarter = current_quarter
      Date.new(year, (quarter - 1) * 3 + 1, 1)..Date.new(year, quarter * 3, -1)
    when "yearly"
      Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end
  end
end

class DataProcessor < RubyLLM::Tool
  description "Processes and analyzes sales data"

  param :data_summary, desc: "Data summary from DataFetcher", type: :object
  param :analysis_type, desc: "Type of analysis: trends, comparison, breakdown"

  def execute(data_summary:, analysis_type:)
    # Process the data based on summary
    processed_results = case analysis_type
    when "trends"
      analyze_trends(data_summary)
    when "comparison"
      compare_periods(data_summary)
    when "breakdown"
      breakdown_by_category(data_summary)
    end

    {
      analysis_type: analysis_type,
      insights: processed_results[:insights],
      metrics: processed_results[:metrics],
      recommendations: processed_results[:recommendations],
      message: "Analysis complete. Found #{processed_results[:insights].length} key insights."
    }
  end
end

class ReportGenerator < RubyLLM::Tool
  description "Generates formatted reports with charts"

  param :data_summary, desc: "Original data summary", type: :object
  param :analysis_results, desc: "Processed analysis results", type: :object
  param :format, desc: "Report format: pdf, html, excel", required: false

  def execute(data_summary:, analysis_results:, format: "pdf")
    # Generate comprehensive report
    report_path = create_report(data_summary, analysis_results, format)
    charts_path = generate_charts(analysis_results)

    RubyLLM::Content.new(
      "Generated #{format.upcase} report with #{analysis_results[:insights].length} insights and #{analysis_results[:metrics].keys.length} key metrics.",
      [report_path, charts_path]
    )
  end
end
```

## Parallel Execution Patterns

Some scenarios benefit from parallel tool execution (though this depends on the AI model's capabilities):

```ruby
class ParallelDataGatherer < RubyLLM::Tool
  description "Gathers data from multiple sources concurrently"

  param :sources, desc: "Array of data sources to query", type: :array

  def execute(sources:)
    # Use Ruby threads for concurrent execution
    results = Parallel.map(sources) do |source|
      gather_from_source(source)
    end

    {
      sources_queried: sources.length,
      total_records: results.sum { |r| r[:record_count] },
      results: results,
      execution_time: "Parallel execution completed in #{Time.current}"
    }
  end

  private

  def gather_from_source(source)
    case source
    when "database"
      query_database
    when "api"
      fetch_from_api
    when "files"
      process_files
    end
  rescue => e
    { source: source, error: e.message, record_count: 0 }
  end
end
```

## Error Handling Strategies

Implement comprehensive error handling for robust tool execution:

```ruby
class RobustExecutionTool < RubyLLM::Tool
  description "Demonstrates comprehensive error handling"

  param :operation, desc: "Operation to perform"
  param :retry_count, desc: "Number of retries for failures", type: :integer, required: false

  def execute(operation:, retry_count: 3)
    attempt = 0
    max_attempts = retry_count + 1

    begin
      attempt += 1
      Rails.logger.info("Attempt #{attempt} of #{max_attempts} for operation: #{operation}")

      result = perform_operation(operation)

      # Log successful execution
      Rails.logger.info("Operation #{operation} completed successfully on attempt #{attempt}")
      result

    rescue RetryableError => e
      if attempt < max_attempts
        delay = exponential_backoff(attempt)
        Rails.logger.warn("Attempt #{attempt} failed: #{e.message}. Retrying in #{delay}s")
        sleep(delay)
        retry
      else
        handle_permanent_failure(operation, e, attempt)
      end

    rescue PermanentError => e
      handle_permanent_failure(operation, e, attempt)

    rescue StandardError => e
      handle_unexpected_error(operation, e, attempt)
    end
  end

  private

  def perform_operation(operation)
    case operation
    when "network_call"
      make_network_request
    when "database_query"
      execute_database_query
    when "file_processing"
      process_large_file
    else
      raise PermanentError, "Unknown operation: #{operation}"
    end
  end

  def exponential_backoff(attempt)
    [2 ** attempt, 30].min  # Cap at 30 seconds
  end

  def handle_permanent_failure(operation, error, attempts)
    Rails.logger.error("Permanent failure for #{operation} after #{attempts} attempts: #{error.message}")

    {
      error: "Operation failed permanently",
      operation: operation,
      attempts: attempts,
      message: error.message,
      suggestion: suggest_alternative(operation)
    }
  end

  def handle_unexpected_error(operation, error, attempt)
    Rails.logger.error("Unexpected error in #{operation} on attempt #{attempt}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))

    {
      error: "Unexpected error occurred",
      operation: operation,
      message: "An unexpected error occurred. Please try again later.",
      support_reference: log_error_for_support(error)
    }
  end

  def suggest_alternative(operation)
    alternatives = {
      "network_call" => "Check your internet connection and try again",
      "database_query" => "Verify the query parameters and database connectivity",
      "file_processing" => "Ensure the file exists and is accessible"
    }

    alternatives[operation] || "Please contact support for assistance"
  end

  # Custom error classes
  class RetryableError < StandardError; end
  class PermanentError < StandardError; end
end
```

## Timeout Management

Implement timeout controls to prevent hanging operations:

```ruby
class TimeoutAwareTool < RubyLLM::Tool
  description "Demonstrates timeout management"

  param :operation_type, desc: "Type of operation: quick, medium, slow"
  param :timeout_seconds, desc: "Custom timeout in seconds", type: :integer, required: false

  def execute(operation_type:, timeout_seconds: nil)
    timeout_duration = timeout_seconds || default_timeout_for(operation_type)

    begin
      Timeout.timeout(timeout_duration) do
        perform_timed_operation(operation_type)
      end
    rescue Timeout::Error
      handle_timeout(operation_type, timeout_duration)
    end
  end

  private

  def default_timeout_for(operation_type)
    case operation_type
    when "quick" then 5
    when "medium" then 30
    when "slow" then 120
    else 60
    end
  end

  def perform_timed_operation(operation_type)
    case operation_type
    when "quick"
      quick_operation
    when "medium"
      medium_operation
    when "slow"
      slow_operation
    end
  end

  def handle_timeout(operation_type, duration)
    Rails.logger.warn("Operation #{operation_type} timed out after #{duration} seconds")

    {
      error: "Operation timed out",
      operation_type: operation_type,
      timeout_duration: duration,
      message: "The operation took longer than expected. You can try again with a longer timeout or simplify the request.",
      suggestion: suggest_timeout_solution(operation_type)
    }
  end

  def suggest_timeout_solution(operation_type)
    case operation_type
    when "slow"
      "Consider breaking this into smaller operations or running it as a background job"
    else
      "Try again with a longer timeout or contact support if the issue persists"
    end
  end
end
```

## Background Job Integration

For long-running operations, integrate with Rails background jobs:

```ruby
class BackgroundJobTool < RubyLLM::Tool
  description "Handles long-running operations via background jobs"

  param :operation, desc: "Operation to perform"
  param :run_async, desc: "Whether to run asynchronously", type: :boolean, required: false

  def execute(operation:, run_async: false)
    if should_run_async?(operation, run_async)
      run_background_job(operation)
    else
      run_synchronously(operation)
    end
  end

  private

  def should_run_async?(operation, explicit_async)
    return true if explicit_async

    # Auto-detect operations that should run async
    long_running_operations = %w[large_report data_export system_backup]
    long_running_operations.include?(operation)
  end

  def run_background_job(operation)
    job = LongRunningOperationJob.perform_later(operation)

    {
      status: "started",
      job_id: job.job_id,
      operation: operation,
      message: "Started #{operation} in the background. Job ID: #{job.job_id}",
      check_status_url: "/jobs/#{job.job_id}/status"
    }
  end

  def run_synchronously(operation)
    start_time = Time.current

    result = case operation
    when "quick_report"
      generate_quick_report
    when "data_summary"
      create_data_summary
    else
      { error: "Unknown operation: #{operation}" }
    end

    result.merge(
      execution_time: (Time.current - start_time).round(2),
      run_mode: "synchronous"
    )
  end
end

# Background job for long-running operations
class LongRunningOperationJob < ApplicationJob
  queue_as :default

  def perform(operation)
    Rails.logger.info("Starting background operation: #{operation}")

    result = case operation
    when "large_report"
      generate_large_report
    when "data_export"
      export_all_data
    when "system_backup"
      perform_system_backup
    end

    # Store result for retrieval
    JobResult.create!(
      job_id: job_id,
      operation: operation,
      result: result,
      completed_at: Time.current
    )

    Rails.logger.info("Completed background operation: #{operation}")
  rescue => e
    Rails.logger.error("Background job failed: #{e.message}")

    JobResult.create!(
      job_id: job_id,
      operation: operation,
      error: e.message,
      failed_at: Time.current
    )

    raise e
  end
end
```

## Conditional Execution Flow

Implement conditional logic for complex execution flows:

```ruby
class ConditionalExecutionTool < RubyLLM::Tool
  description "Demonstrates conditional execution patterns"

  param :workflow, desc: "Workflow to execute"
  param :conditions, desc: "Conditions for execution", type: :object

  def execute(workflow:, conditions:)
    execution_plan = build_execution_plan(workflow, conditions)

    results = []
    execution_plan.each do |step|
      if should_execute_step?(step, conditions, results)
        step_result = execute_step(step)
        results << step_result

        # Early termination conditions
        if step_result[:terminate]
          break
        end
      else
        results << { step: step[:name], status: "skipped", reason: step[:skip_reason] }
      end
    end

    {
      workflow: workflow,
      execution_summary: summarize_execution(results),
      detailed_results: results
    }
  end

  private

  def build_execution_plan(workflow, conditions)
    case workflow
    when "data_processing"
      [
        { name: "validate_input", required: true },
        { name: "fetch_data", required: true },
        { name: "clean_data", condition: conditions[:needs_cleaning] },
        { name: "transform_data", condition: conditions[:needs_transform] },
        { name: "analyze_data", required: true },
        { name: "generate_report", condition: conditions[:generate_report] }
      ]
    when "user_onboarding"
      [
        { name: "create_account", required: true },
        { name: "send_welcome_email", condition: conditions[:send_email] },
        { name: "setup_preferences", condition: conditions[:has_preferences] },
        { name: "assign_mentor", condition: conditions[:needs_mentor] }
      ]
    end
  end

  def should_execute_step?(step, conditions, previous_results)
    return true if step[:required]
    return false unless step[:condition]

    # Check if previous steps succeeded
    if step[:depends_on]
      dependency_met = previous_results.any? do |result|
        result[:step] == step[:depends_on] && result[:status] == "success"
      end
      return false unless dependency_met
    end

    step[:condition]
  end

  def execute_step(step)
    Rails.logger.info("Executing step: #{step[:name]}")

    begin
      case step[:name]
      when "validate_input"
        validate_input_step
      when "fetch_data"
        fetch_data_step
      when "clean_data"
        clean_data_step
      # Add other step implementations
      else
        { step: step[:name], status: "error", message: "Unknown step" }
      end
    rescue => e
      {
        step: step[:name],
        status: "error",
        message: e.message,
        terminate: step[:critical] # Stop execution if critical step fails
      }
    end
  end
end
```

## Monitoring and Metrics

Track tool execution for performance optimization:

```ruby
class MonitoredTool < RubyLLM::Tool
  description "Demonstrates execution monitoring"

  def execute(**params)
    execution_id = SecureRandom.uuid
    start_time = Time.current

    begin
      ToolMetrics.start_execution(execution_id, self.class.name, params)

      result = perform_monitored_operation(params)

      ToolMetrics.complete_execution(
        execution_id,
        duration: Time.current - start_time,
        success: true
      )

      result
    rescue => e
      ToolMetrics.complete_execution(
        execution_id,
        duration: Time.current - start_time,
        success: false,
        error: e.message
      )

      raise e
    end
  end

  private

  def perform_monitored_operation(params)
    # Your tool logic here
    { result: "Operation completed", params: params }
  end
end

# Metrics tracking model
class ToolMetrics < ApplicationRecord
  scope :successful, -> { where(success: true) }
  scope :failed, -> { where(success: false) }

  def self.start_execution(execution_id, tool_name, params)
    create!(
      execution_id: execution_id,
      tool_name: tool_name,
      parameters: params,
      started_at: Time.current
    )
  end

  def self.complete_execution(execution_id, duration:, success:, error: nil)
    metric = find_by(execution_id: execution_id)
    return unless metric

    metric.update!(
      duration: duration,
      success: success,
      error_message: error,
      completed_at: Time.current
    )
  end
end
```

## Next Steps

- Explore [Callbacks](tools-callbacks.md) - monitoring and responding to tool events
- Learn about [Halting](tools-halting.md) - controlling tool execution flow and stopping operations
- Understand [MCP Integration](tools-mcp.md) - using Model Context Protocol with tools