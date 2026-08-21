module SuperAdmin::FeaturesHelper
  def self.available_features
    YAML.load(ERB.new(Rails.root.join('app/helpers/super_admin/features.yml').read).result).with_indifferent_access
  end

  # Read locally. This used to name a plan that a remote hub decided, on an
  # installation that may never contact one.
  def self.plan_details
    plan = Lla::Entitlements.plan
    quantity = Lla::Entitlements.seat_count

    if quantity.positive?
      "This installation runs the <span class='font-semibold'>#{plan}</span> plan, licensed for " \
        "<span class='font-semibold'>#{quantity} agents</span>."
    else
      "This installation runs the <span class='font-semibold'>#{plan}</span> plan."
    end
  end
end
