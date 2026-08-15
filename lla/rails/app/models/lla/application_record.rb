# frozen_string_literal: true

# Cho phép template liquid truy cập SlaPolicy qua SlaPolicyDrop.
# Prepend qua `ApplicationRecord.prepend_mod_with('ApplicationRecord')` (MIT).
module Lla::ApplicationRecord
  def droppables
    super + %w[SlaPolicy]
  end
end
