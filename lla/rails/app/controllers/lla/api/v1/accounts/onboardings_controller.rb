# frozen_string_literal: true

module Lla::Api::V1::Accounts::OnboardingsController
  private

  def onboarding_inbox_setup_enabled?
    Lla::Knowledge::ProviderPolicy.capability_enabled?(:onboarding_workspace) || super
  end

  def create_onboarding_inboxes
    super
    create_lla_help_center
  end

  def complete_inbox_setup
    if current_step == self.class::STEP_INBOX_SETUP
      @account.custom_attributes.delete('lla_knowledge_generation_operation_id')
      @account.custom_attributes.delete('help_center_generation_id')
    end
    super
  end

  def create_lla_help_center
    return unless Lla::Knowledge::ProviderPolicy.capability_enabled?(:onboarding_workspace)
    return if website.blank?

    Onboarding::HelpCenterCreationService.new(@account, Current.user).perform
  end

  def website
    custom_attributes_params[:website]
  end

  def help_center_generation_status
    operation = current_knowledge_operation
    return super if operation.blank?

    {
      generation_id: operation.id,
      state: operation_state(operation),
      articles_count: operation.portal.articles.count,
      categories_count: operation.portal.categories.count
    }
  end

  def current_knowledge_operation
    operation_id = @account.custom_attributes['lla_knowledge_generation_operation_id']
    return if operation_id.blank?

    Lla::Knowledge::GenerationOperation.includes(:portal).find_by(account: @account, id: operation_id)
  end

  def operation_state(operation)
    {
      status: public_operation_state(operation.state),
      total: operation.expected_items,
      finished: operation.finished_items,
      errors: operation.failed_items
    }
  end

  def public_operation_state(state)
    return 'generating' if state.in?(%w[pending planning dispatching running])

    state
  end
end
