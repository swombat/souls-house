# A rhythm can say which model each of its residents runs on in the
# conversations it opens. nil follows the resident's default; a model id is
# copied onto the seat (chat_agents.model_id) when an occurrence opens.
class AddModelIdToRhythmAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :rhythm_agents, :model_id, :string
  end

end
