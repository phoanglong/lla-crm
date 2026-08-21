module Llm::FeatureRouter
  class UnknownFeatureError < StandardError; end

  CAPTAIN_V2_ASSISTANT_MODEL = 'gpt-5.2'.freeze

  class << self
    def resolve(feature:, account: nil)
      feature_key = feature.to_s
      raise UnknownFeatureError, "Unknown LLM feature: #{feature_key}" unless Llm::Models.feature?(feature_key)

      model = account_model_override(account, feature_key)
      source = model.present? ? :account_override : :default
      model ||= captain_v2_assistant_model(account, feature_key)
      model ||= Llm::Models.default_model_for(feature_key)

      credential = Lla::Ai::CredentialResolver.resolve(account: account, model: model)

      {
        feature: feature_key,
        # Mô hình của nhà cung cấp do tenant khai không nằm trong danh mục của bản cài đặt,
        # nên nhà cung cấp đọc từ chính kết nối ấy chứ không suy ra từ tên mô hình.
        provider: credential.provider_name || Llm::Models.provider_for(model),
        model: model,
        source: source,
        credential: credential
      }
    end

    private

    # Mô hình hợp lệ là mô hình danh mục của bản cài đặt cho phép, **hoặc** mô hình của một
    # nhà cung cấp do chính tenant khai (`<tên>/<mô hình>`). Vế thứ hai mới là điều làm cho
    # "mang AI của mình" có nghĩa: danh mục do LLA giữ không thể biết trước mọi mô hình khách
    # sẽ chạy.
    def account_model_override(account, feature_key)
      model = account&.captain_models&.[](feature_key).presence
      return unless model
      return model if Llm::Models.valid_model_for?(feature_key, model)
      return model if tenant_model?(account, model)
    end

    def tenant_model?(account, model)
      name, = Lla::Ai::CredentialResolver.split(model)
      return false if name.blank?

      account&.lla_ai_providers&.enabled&.exists?(name: name) || false
    end

    def captain_v2_assistant_model(account, feature_key)
      return unless feature_key == 'assistant'
      return unless account&.feature_enabled?('captain_integration_v2')

      CAPTAIN_V2_ASSISTANT_MODEL
    end
  end
end
