require 'administrate/field/base'

# Per-account limits in the operator console. Ported from the enterprise field so
# the control plane keeps working with enterprise off.
class Lla::AccountLimitsField < Administrate::Field::Base
  DEFAULTS = { agents: nil, inboxes: nil, captain_responses: nil, captain_documents: nil, emails: nil }.freeze

  def to_s
    overrides = (data.presence || {}).to_h.symbolize_keys.compact
    DEFAULTS.merge(overrides).to_json
  end
end
