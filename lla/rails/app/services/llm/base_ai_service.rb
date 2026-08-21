# frozen_string_literal: true

# LLA-owned base for RubyLLM services. Cả mô hình lẫn credential đều theo tenant: mô hình
# viết dạng `<nhà cung cấp>/<mô hình>` sẽ được gọi bằng khoá và endpoint của kết nối do chính
# tenant khai, thay vì cấu hình chung của tiến trình.
class Llm::BaseAiService
  DEFAULT_MODEL = Llm::Config::DEFAULT_MODEL
  DEFAULT_TEMPERATURE = 1.0

  attr_reader :model, :temperature

  def initialize(feature: nil, account: nil, fallback_model: nil)
    @llm_feature = feature
    @llm_account = account
    @fallback_model = fallback_model

    Llm::Config.initialize!
    setup_model
    setup_temperature
  end

  def chat(model: @model, temperature: @temperature)
    credential = Lla::Ai::CredentialResolver.resolve(account: @llm_account, model: model)

    Llm::Config.with_credential(credential) do |context|
      context.chat(model: credential.model).with_temperature(temperature)
    end
  end

  private

  def sanitize_json_response(response)
    return response if response.nil?

    response.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end

  def setup_model
    route = feature_route
    return @model = route[:model] if account_override_route?(route) || captain_v2_assistant?

    @model = @fallback_model.presence || installation_model.presence || route&.dig(:model) || DEFAULT_MODEL
  end

  def feature_route
    return if @llm_feature.blank?

    Llm::FeatureRouter.resolve(feature: @llm_feature, account: @llm_account)
  end

  def account_override_route?(route)
    route&.dig(:source) == :account_override
  end

  def captain_v2_assistant?
    @llm_feature.to_s == 'assistant' && @llm_account&.feature_enabled?('captain_integration_v2')
  end

  def installation_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
  end

  def setup_temperature
    @temperature = DEFAULT_TEMPERATURE
  end
end
