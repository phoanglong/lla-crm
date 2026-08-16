# frozen_string_literal: true

module Lla::SuperAdmin::AccountsController
  def update
    previous_models = requested_resource.captain_models&.deep_dup

    Account.transaction do
      super.tap do
        record_captain_model_override_audit(previous_models) if requested_resource.errors.empty?
      end
    end
  end

  private

  def record_captain_model_override_audit(previous_models)
    Lla::Captain::ModelOverrideAudit.new(
      account: requested_resource,
      previous_models: previous_models,
      actor: current_super_admin,
      request: request
    ).record!
  end
end
