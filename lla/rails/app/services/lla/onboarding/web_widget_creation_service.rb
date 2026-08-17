# frozen_string_literal: true

module Lla::Onboarding::WebWidgetCreationService
  private

  def welcome_tagline_text
    return super unless tagline_egress_permitted?

    response = Captain::Llm::WidgetTaglineService.new(account: @account).perform
    response&.dig(:message).to_s.strip.presence || super
  rescue StandardError => e
    Rails.logger.warn("LLA widget tagline fallback account_id=#{@account.id} error_class=#{e.class.name}")
    super
  end

  def tagline_egress_permitted?
    Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: @account,
      provider: :openai,
      capability: :widget_tagline
    )
  end
end
