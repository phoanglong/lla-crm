# frozen_string_literal: true

# Assigning a custom role to an agent.
#
# The read side of custom roles is community code — `_agent.json.jbuilder` renders
# `custom_role_id` whenever `ChatwootApp.custom_roles?` — but the only place that
# ever *wrote* it was an enterprise extension. With enterprise off, custom roles
# were visible and unassignable.
module Lla::Api::V1::Accounts::AgentsController
  def create
    super
    return if @agent.blank?

    associate_agent_with_custom_role
  end

  def update
    super
    associate_agent_with_custom_role
  end

  private

  # The role has to belong to this account. `Lla::AccountUser` validates that on
  # write, so a forged id fails there rather than being stored; this resolves it
  # against the account first so the caller gets a 404 instead of a validation
  # error naming an id they should not have known about.
  def associate_agent_with_custom_role
    return unless params.key?(:custom_role_id)

    role_id = params[:custom_role_id].presence
    resolved = role_id && Current.account.custom_roles.where(id: role_id).pick(:id)
    raise ActiveRecord::RecordNotFound if role_id.present? && resolved.blank?

    @agent.current_account_user.update!(custom_role_id: resolved)
  end
end
