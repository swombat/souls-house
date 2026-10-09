module HouseSampling
  # CPU and memory per resident container, from one `docker stats` call.
  # Returns { agent_id => { "cpu" => percent of one core, "mem" => bytes } }.
  # Docker reports CPU as a percentage of one core: 100% is one busy core.
  class ContainerStats

    UNITS = { "B" => 1, "KB" => 1000, "MB" => 1000**2, "GB" => 1000**3, "TB" => 1000**4,
              "KIB" => 1024, "MIB" => 1024**2, "GIB" => 1024**3, "TIB" => 1024**4 }.freeze

    def call
      agents = Agent.where.not(container_name: [ nil, "" ]).pluck(:container_name, :id).to_h
      return {} if agents.empty?
      command = BoundedCommand.run("docker", "stats", "--no-stream", "--format", "{{json .}}", timeout: 30)
      return {} unless command.ok
      command.stdout.lines.each_with_object({}) do |line, stats|
        row = JSON.parse(line)
        agent_id = agents[row["Name"]]
        next unless agent_id
        stats[agent_id.to_s] = { "cpu" => row["CPUPerc"].to_f.round(2), "mem" => bytes(row["MemUsage"].to_s.split("/").first) }
      rescue JSON::ParserError
        next
      end
    end

    private

    def bytes(text)
      match = text.to_s.strip.match(/\A([\d.]+)\s*([a-zA-Z]+)\z/)
      return nil unless match
      (match[1].to_f * UNITS.fetch(match[2].upcase, 1)).round
    end

  end
end
