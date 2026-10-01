# Opt-in external-provider evaluation, never run by the test suite.
# bin/rails runner scripts/evaluate-real-reply-attention.rb INPUT.json SPLIT OUTPUT.jsonl RECIPIENT_NAME
# INPUT is privately labelled, authorised conversational text; do not commit it.
# Each row has id, source_id, chat, split, author, content, kind, expected, context.
# Context rows have id, user_id (1 for the recipient, otherwise null), author, content.
# Only scored/ambiguous rows reach inference. Labels never reach the provider.
# Uses plain structs: no production message import or attention-marker writes.
module RealReplyAttentionEvaluation

  Person = Struct.new(:id, :full_name)
  MessageData = Struct.new(:id, :user_id, :user, :agent, :content, :chat, :chat_id, :runtime_interaction)
  ChatData = Struct.new(:messages, :agents)
  AgentData = Struct.new(:name, :id)

  class ContextData

    def initialize(messages) = @messages = messages
    def kept = self
    def where(*) = self
    def reorder(*) = self
    def limit(*) = self
    def reverse = @messages

  end

  def self.run(input, split, output, recipient_name)
    rows = JSON.parse(File.read(input))
    person = Person.new(1, recipient_name)
    # Refuse to overwrite a prior run: held-out results must remain inspectable.
    File.open(output, "wx", 0o600) do |file|
      rows.select { |row| row["split"] == split && %w[scored ambiguous].include?(row["kind"]) }.each do |row|
        agents = row.fetch("agents", [ row.fetch("author") ]).each_with_index.map { |name, i| AgentData.new(name, i + 1) }
        context = row.fetch("context").map do |item|
          MessageData.new(item["id"], item["user_id"], item["user_id"] ? person : nil,
            AgentData.new(item["author"]), item["content"], nil)
        end
        message = MessageData.new(row.fetch("id"), nil, nil, AgentData.new(row.fetch("author")),
          row.fetch("content"), ChatData.new(ContextData.new(context), agents))
        classifier = ReplyExpectationClassifier.new(messages: [ message ], users: [ person ])
        result = row.slice("chat", "source_id", "split", "expected", "kind")
          .merge("version" => ReplyExpectationClassifier::VERSION, "threshold" => ReplyExpectationClassifier::THRESHOLD)
        begin
          decisions = classifier.call
          result["response_probability"] = classifier.probabilities.fetch("m#{row['id']}_reply")
          result["uncertain"] = !decisions.key?(message.id)
          result["detected"] = decisions.fetch(message.id, {}).key?(person.id)
        rescue UtilityInference::Error => error
          result["error"] = error.class.name
        end
        file.puts(result.to_json)
        file.flush
        puts result.to_json
        $stdout.flush
      end
    end
  end

end

RealReplyAttentionEvaluation.run(*ARGV.take(4))
