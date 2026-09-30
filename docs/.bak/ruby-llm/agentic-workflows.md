# Agentic Workflows with RubyLLM

This document covers advanced agentic workflow patterns and techniques for building sophisticated AI agent systems using RubyLLM.

## Overview

Agentic workflows enable the creation of intelligent, autonomous systems that can make decisions, coordinate tasks, and execute complex operations. RubyLLM provides the foundation for building these systems with its unified API and powerful abstractions.

## Key Agentic Workflow Patterns

### 1. Model Routing

Dynamic model selection based on task requirements and context.

```ruby
class ModelRouter
  def self.route_request(task_type, content)
    case task_type
    when :code_generation
      RubyLLM.chat(model: 'claude-3-sonnet')
    when :creative_writing
      RubyLLM.chat(model: 'gpt-4')
    when :factual_analysis
      RubyLLM.chat(model: 'gemini-pro')
    else
      RubyLLM.chat # Default model
    end
  end
end

# Usage
router = ModelRouter.route_request(:code_generation, "Write a Ruby method")
response = router.ask("Create a method to parse CSV files")
```

### 2. Retrieval-Augmented Generation (RAG)

Integrate external knowledge bases with AI responses using vector embeddings and semantic search.

```ruby
class RAGAgent
  def initialize
    @embeddings = RubyLLM.embeddings
    @chat = RubyLLM.chat
  end

  def search_and_answer(query, knowledge_base)
    # Generate embedding for query
    query_embedding = @embeddings.embed(query)

    # Find relevant documents using pgvector
    relevant_docs = find_similar_documents(query_embedding, knowledge_base)

    # Augment query with context
    context = relevant_docs.map(&:content).join("\n\n")
    augmented_query = "Context: #{context}\n\nQuestion: #{query}"

    @chat.ask(augmented_query)
  end

  private

  def find_similar_documents(embedding, knowledge_base)
    # Use PostgreSQL with pgvector for efficient similarity search
    knowledge_base.where(
      "embedding <-> ? < 0.3",
      embedding.to_s
    ).limit(5)
  end
end
```

### 3. Multi-Agent Systems

Create specialized agents with distinct roles and capabilities.

```ruby
class MultiAgentSystem
  def initialize
    @research_agent = create_research_agent
    @analysis_agent = create_analysis_agent
    @writing_agent = create_writing_agent
  end

  def process_complex_task(task)
    # Parallel execution of agent tasks
    research_results = async_execute(@research_agent, :research, task)
    analysis_results = async_execute(@analysis_agent, :analyze, research_results)
    final_output = async_execute(@writing_agent, :synthesize, analysis_results)

    final_output
  end

  private

  def create_research_agent
    RubyLLM.chat.tap do |agent|
      agent.system_prompt = "You are a research specialist. Focus on gathering comprehensive information."
    end
  end

  def create_analysis_agent
    RubyLLM.chat.tap do |agent|
      agent.system_prompt = "You are an analytical expert. Focus on identifying patterns and insights."
    end
  end

  def create_writing_agent
    RubyLLM.chat.tap do |agent|
      agent.system_prompt = "You are a technical writer. Focus on clear, structured communication."
    end
  end

  def async_execute(agent, method, data)
    # Use Ruby's async capabilities for concurrent execution
    Async do
      agent.send(method, data)
    end
  end
end
```

## State Management

### Agent Memory and Context

Implement persistent state and memory for agents across interactions.

```ruby
class StatefulAgent
  attr_accessor :memory, :context

  def initialize
    @chat = RubyLLM.chat
    @memory = {}
    @context = []
  end

  def process_with_memory(input)
    # Add to conversation context
    @context << { role: 'user', content: input }

    # Include relevant memory in prompt
    memory_context = build_memory_context(input)
    full_prompt = "#{memory_context}\n\nCurrent request: #{input}"

    response = @chat.ask(full_prompt)

    # Store response in context and extract key information for memory
    @context << { role: 'assistant', content: response }
    update_memory(input, response)

    response
  end

  private

  def build_memory_context(input)
    relevant_memories = @memory.select { |key, value| input.include?(key) }
    return "" if relevant_memories.empty?

    "Previous context:\n#{relevant_memories.map { |k, v| "#{k}: #{v}" }.join("\n")}"
  end

  def update_memory(input, response)
    # Extract and store key information
    key_info = extract_key_information(input, response)
    @memory.merge!(key_info)

    # Limit memory size to prevent context overflow
    @memory = @memory.last(50).to_h if @memory.size > 100
  end

  def extract_key_information(input, response)
    # Simple keyword extraction - could be enhanced with NLP
    keywords = input.scan(/\b[A-Z][a-z]+\b/)
    keywords.each_with_object({}) do |keyword, memo|
      memo[keyword.downcase] = response.slice(0, 100) + "..."
    end
  end
end
```

## Workflow Orchestration

### Supervisor Pattern

Coordinate multiple agents with a central supervisor.

```ruby
class WorkflowSupervisor
  def initialize
    @agents = {
      data_collector: DataCollectorAgent.new,
      analyzer: AnalyzerAgent.new,
      reporter: ReporterAgent.new
    }
    @workflow_state = {}
  end

  def execute_workflow(task)
    workflow_id = SecureRandom.uuid
    @workflow_state[workflow_id] = { status: 'started', steps: [] }

    begin
      # Step 1: Data Collection
      data = execute_step(workflow_id, :data_collector, :collect, task)

      # Step 2: Analysis
      analysis = execute_step(workflow_id, :analyzer, :analyze, data)

      # Step 3: Report Generation
      report = execute_step(workflow_id, :reporter, :generate_report, analysis)

      @workflow_state[workflow_id][:status] = 'completed'
      report
    rescue => e
      @workflow_state[workflow_id][:status] = 'failed'
      @workflow_state[workflow_id][:error] = e.message
      raise
    end
  end

  private

  def execute_step(workflow_id, agent_name, method, data)
    step_info = { agent: agent_name, method: method, started_at: Time.current }

    result = @agents[agent_name].send(method, data)

    step_info[:completed_at] = Time.current
    step_info[:success] = true
    @workflow_state[workflow_id][:steps] << step_info

    result
  rescue => e
    step_info[:completed_at] = Time.current
    step_info[:success] = false
    step_info[:error] = e.message
    @workflow_state[workflow_id][:steps] << step_info

    raise
  end
end
```

## Decision Making

### Conditional Logic and Branching

Implement intelligent decision-making within workflows.

```ruby
class DecisionMakingAgent
  def initialize
    @chat = RubyLLM.chat
    @decision_history = []
  end

  def make_decision(context, options)
    decision_prompt = build_decision_prompt(context, options)

    # Use structured output for reliable decision parsing
    schema = {
      type: 'object',
      properties: {
        decision: { type: 'string', enum: options },
        reasoning: { type: 'string' },
        confidence: { type: 'number', minimum: 0, maximum: 1 }
      },
      required: ['decision', 'reasoning', 'confidence']
    }

    response = @chat.ask(decision_prompt, schema: schema)
    decision_data = JSON.parse(response)

    # Log decision for future reference
    @decision_history << {
      context: context,
      decision: decision_data['decision'],
      reasoning: decision_data['reasoning'],
      confidence: decision_data['confidence'],
      timestamp: Time.current
    }

    decision_data
  end

  def evaluate_decision_quality
    # Analyze decision patterns and success rates
    @decision_history.group_by { |d| d[:decision] }.transform_values do |decisions|
      {
        count: decisions.size,
        avg_confidence: decisions.sum { |d| d[:confidence] } / decisions.size,
        recent_trend: decisions.last(5).map { |d| d[:confidence] }
      }
    end
  end

  private

  def build_decision_prompt(context, options)
    past_decisions = @decision_history.last(3).map do |d|
      "Previous decision: #{d[:decision]} (confidence: #{d[:confidence]}) - #{d[:reasoning]}"
    end.join("\n")

    <<~PROMPT
      Context: #{context}

      Available options: #{options.join(', ')}

      Recent decision history:
      #{past_decisions}

      Make the best decision based on the context. Consider past decisions and their outcomes.
      Provide your reasoning and confidence level (0-1).
    PROMPT
  end
end
```

## Complex Workflow Examples

### Research and Analysis Pipeline

```ruby
class ResearchPipeline
  def initialize
    @agents = {
      web_researcher: create_web_research_agent,
      document_analyzer: create_document_analysis_agent,
      fact_checker: create_fact_checking_agent,
      synthesizer: create_synthesis_agent
    }
  end

  def research_topic(topic, depth: :standard)
    workflow = WorkflowBuilder.new
      .add_step(:web_research, @agents[:web_researcher], :search, topic)
      .add_step(:document_analysis, @agents[:document_analyzer], :analyze_documents)
      .add_step(:fact_checking, @agents[:fact_checker], :verify_facts)
      .add_step(:synthesis, @agents[:synthesizer], :create_report)
      .build

    workflow.execute(depth: depth)
  end

  private

  def create_web_research_agent
    RubyLLM.chat.tap do |agent|
      agent.tools = [web_search_tool, content_extraction_tool]
      agent.system_prompt = "You are a web research specialist. Gather comprehensive information from reliable sources."
    end
  end

  def create_document_analysis_agent
    RubyLLM.chat.tap do |agent|
      agent.system_prompt = "You are a document analysis expert. Extract key insights and patterns from research materials."
    end
  end

  def create_fact_checking_agent
    RubyLLM.chat.tap do |agent|
      agent.tools = [fact_verification_tool]
      agent.system_prompt = "You are a fact-checking specialist. Verify information accuracy and identify potential biases."
    end
  end

  def create_synthesis_agent
    RubyLLM.chat.tap do |agent|
      agent.system_prompt = "You are a synthesis expert. Create coherent, well-structured reports from analyzed information."
    end
  end
end
```

### Adaptive Learning System

```ruby
class AdaptiveLearningAgent
  def initialize
    @base_chat = RubyLLM.chat
    @performance_metrics = {}
    @learning_rate = 0.1
  end

  def process_task(task, expected_outcome: nil)
    # Generate initial response
    response = @base_chat.ask(build_adaptive_prompt(task))

    # If expected outcome provided, learn from the result
    if expected_outcome
      success_score = evaluate_response(response, expected_outcome)
      update_performance_metrics(task, success_score)

      # Adapt approach based on performance
      if success_score < 0.7
        response = retry_with_adaptation(task, response)
      end
    end

    response
  end

  private

  def build_adaptive_prompt(task)
    # Incorporate learned patterns into prompt
    relevant_patterns = find_relevant_patterns(task)

    base_prompt = "Task: #{task}"

    if relevant_patterns.any?
      pattern_guidance = relevant_patterns.map do |pattern|
        "Based on similar tasks, consider: #{pattern}"
      end.join("\n")

      base_prompt += "\n\nLearned patterns:\n#{pattern_guidance}"
    end

    base_prompt
  end

  def evaluate_response(response, expected_outcome)
    # Simple similarity evaluation - could be enhanced with more sophisticated metrics
    similarity_chat = RubyLLM.chat
    evaluation_prompt = <<~PROMPT
      Response: #{response}
      Expected: #{expected_outcome}

      Rate the similarity and quality of the response compared to the expected outcome.
      Provide a score from 0 to 1 where 1 is perfect match and 0 is completely wrong.
      Return only the numeric score.
    PROMPT

    similarity_chat.ask(evaluation_prompt).to_f
  end

  def update_performance_metrics(task, score)
    task_type = classify_task_type(task)

    @performance_metrics[task_type] ||= { scores: [], patterns: [] }
    @performance_metrics[task_type][:scores] << score

    # Extract successful patterns when score is high
    if score > 0.8
      @performance_metrics[task_type][:patterns] << extract_success_pattern(task, score)
    end
  end

  def find_relevant_patterns(task)
    task_type = classify_task_type(task)
    @performance_metrics.dig(task_type, :patterns) || []
  end

  def retry_with_adaptation(task, previous_response)
    adaptation_prompt = <<~PROMPT
      Previous attempt: #{previous_response}
      Original task: #{task}

      The previous response was not optimal. Please improve the approach by:
      1. Analyzing what might have been missing
      2. Providing a more comprehensive solution
      3. Double-checking your reasoning
    PROMPT

    @base_chat.ask(adaptation_prompt)
  end

  def classify_task_type(task)
    # Simple classification - could be enhanced with ML
    case task.downcase
    when /code|programming|development/
      :coding
    when /analysis|analyze|data/
      :analysis
    when /creative|write|story/
      :creative
    else
      :general
    end
  end

  def extract_success_pattern(task, score)
    # Extract pattern from successful task completion
    "Task type: #{classify_task_type(task)}, Success score: #{score}"
  end
end
```

## Best Practices

### Error Handling and Resilience

```ruby
class ResilientAgent
  def initialize
    @chat = RubyLLM.chat
    @retry_count = 3
    @backoff_multiplier = 2
  end

  def execute_with_resilience(task)
    attempt = 0

    begin
      attempt += 1
      @chat.ask(task)
    rescue => e
      if attempt < @retry_count
        sleep_time = @backoff_multiplier ** (attempt - 1)
        sleep(sleep_time)
        retry
      else
        handle_final_failure(task, e)
      end
    end
  end

  private

  def handle_final_failure(task, error)
    fallback_response = "I encountered an error processing your request: #{error.message}. " \
                       "Please try rephrasing your request or contact support if the issue persists."

    # Log error for analysis
    log_error(task, error)

    fallback_response
  end

  def log_error(task, error)
    Rails.logger.error "Agent execution failed: Task=#{task}, Error=#{error.message}, Backtrace=#{error.backtrace.first(5)}"
  end
end
```

### Performance Optimization

```ruby
class OptimizedAgent
  def initialize
    @chat = RubyLLM.chat
    @cache = Rails.cache
    @cache_ttl = 1.hour
  end

  def cached_ask(query, cache_key: nil)
    cache_key ||= generate_cache_key(query)

    @cache.fetch(cache_key, expires_in: @cache_ttl) do
      @chat.ask(query)
    end
  end

  def batch_process(queries)
    # Process multiple queries concurrently
    queries.map do |query|
      Concurrent::Future.execute do
        cached_ask(query)
      end
    end.map(&:value)
  end

  private

  def generate_cache_key(query)
    "agent_response:#{Digest::SHA256.hexdigest(query)}"
  end
end
```

## Integration with Rails Applications

### Controller Integration

```ruby
class AgenticController < ApplicationController
  before_action :initialize_agents

  def process_complex_request
    result = @multi_agent_system.process_complex_task(params[:task])

    render json: {
      status: 'success',
      result: result,
      workflow_id: @multi_agent_system.current_workflow_id
    }
  rescue => e
    render json: {
      status: 'error',
      message: e.message
    }, status: 500
  end

  private

  def initialize_agents
    @multi_agent_system = MultiAgentSystem.new
  end
end
```

### Background Job Integration

```ruby
class AgenticWorkflowJob < ApplicationJob
  queue_as :default

  def perform(workflow_type, parameters)
    agent_system = create_agent_system(workflow_type)
    result = agent_system.execute_workflow(parameters)

    # Store results and notify completion
    store_workflow_result(workflow_type, result)
    notify_workflow_completion(workflow_type, result)
  end

  private

  def create_agent_system(workflow_type)
    case workflow_type
    when 'research'
      ResearchPipeline.new
    when 'analysis'
      AnalysisPipeline.new
    else
      GenericWorkflowSystem.new
    end
  end

  def store_workflow_result(workflow_type, result)
    WorkflowResult.create!(
      workflow_type: workflow_type,
      result: result,
      completed_at: Time.current
    )
  end

  def notify_workflow_completion(workflow_type, result)
    # Send notification via ActionCable, email, etc.
    ActionCable.server.broadcast(
      "workflow_channel",
      {
        type: 'workflow_completed',
        workflow_type: workflow_type,
        result: result
      }
    )
  end
end
```

## Monitoring and Analytics

### Agent Performance Tracking

```ruby
class AgentMonitor
  def self.track_agent_performance(agent_name, &block)
    start_time = Time.current

    begin
      result = yield

      log_performance(agent_name, start_time, Time.current, 'success', result)
      result
    rescue => e
      log_performance(agent_name, start_time, Time.current, 'error', e.message)
      raise
    end
  end

  private

  def self.log_performance(agent_name, start_time, end_time, status, result)
    duration = end_time - start_time

    AgentPerformanceLog.create!(
      agent_name: agent_name,
      duration: duration,
      status: status,
      result_summary: result.to_s.truncate(500),
      executed_at: start_time
    )
  end
end
```

This comprehensive guide provides the foundation for building sophisticated agentic workflows with RubyLLM. The patterns and examples can be adapted and extended based on specific use cases and requirements.