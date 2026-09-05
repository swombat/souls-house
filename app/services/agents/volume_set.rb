module Agents
  class VolumeSet

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    def names
      Agents::Resources.new(agent).volumes
    end

    def each(&block)
      names.each(&block)
    end

  end
end
