require 'administrate/field/base'

# The account's feature set in the operator console. Ported from the enterprise
# field so the control plane keeps working with enterprise off.
class Lla::AccountFeaturesField < Administrate::Field::Base
  def to_s
    data
  end
end
