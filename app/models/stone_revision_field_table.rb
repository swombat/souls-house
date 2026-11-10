# A Field table an interactive stone revision reads (slice 2 of Field tables).
# Its rows are public through the stone while this row exists; deleting it
# (Detach on the table page) stops that at once.
class StoneRevisionFieldTable < ApplicationRecord

  MAX_PER_REVISION = 5

  belongs_to :stone_revision
  belongs_to :field_table
  belongs_to :attached_by, polymorphic: true, optional: true

end
