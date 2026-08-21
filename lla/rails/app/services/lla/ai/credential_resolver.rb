# frozen_string_literal: true

# Trả lời một câu duy nhất: **gọi mô hình này bằng khoá nào, tới đâu, theo giao thức nào.**
#
# Trước đây câu trả lời là hằng số của cả tiến trình — một khoá, một endpoint, đọc từ
# `InstallationConfig` lúc khởi động. Ở đây nó là một hàm của tenant, nên hai tenant dùng hai
# nhà cung cấp khác nhau trong cùng một tiến trình mà không đụng nhau.
#
# Tên mô hình có hai dạng:
#   `gpt-4.1-mini`            — mô hình trong danh mục của bản cài đặt, dùng khoá của LLA
#   `noi-bo/llama-3.1-70b`    — mô hình của nhà cung cấp tên `noi-bo` do tenant khai
class Lla::Ai::CredentialResolver
  Credential = Struct.new(:kind, :model, :api_key, :api_base, :source, :provider_name, keyword_init: true) do
    def account?
      source == :account
    end
  end

  class << self
    def resolve(account:, model:)
      provider_name, bare_model = split(model)
      provider = provider_name && find_provider(account, provider_name)
      return account_credential(provider, bare_model) if provider

      system_credential(model)
    end

    # Kết nối của tenant thắng; không có thì dùng credential mà người gọi đã tự lo (hook
    # OpenAI của tài khoản, hoặc khoá của bản cài đặt) và endpoint mà người gọi đang dùng.
    def resolve_with_fallback(account:, model:, fallback:, api_base:)
      tenant = resolve(account: account, model: model)
      return tenant if tenant.source == :account

      Credential.new(
        kind: 'openai', model: model, api_key: fallback&.dig(:api_key),
        api_base: api_base, source: fallback&.dig(:source)
      )
    end

    # `<nhà cung cấp>/<mô hình>`. Tên nhà cung cấp không chứa dấu `/` (ràng buộc ở CSDL), nên
    # một lần tách là đủ và các mô hình có dấu `/` trong tên (kiểu OpenRouter) vẫn nguyên vẹn.
    def split(model)
      name, rest = model.to_s.split('/', 2)
      return [nil, model.to_s] if rest.blank?

      [name, rest]
    end

    private

    def find_provider(account, name)
      account&.lla_ai_providers&.enabled&.find_by(name: name)
    end

    def account_credential(provider, model)
      Credential.new(
        kind: provider.kind, model: model, api_key: provider.api_key, api_base: provider.api_base,
        source: :account, provider_name: provider.name
      )
    end

    # Không có nhà cung cấp riêng thì vẫn là đường cũ: khoá và endpoint của bản cài đặt.
    def system_credential(model)
      Credential.new(
        kind: 'openai', model: model,
        api_key: InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value,
        api_base: InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence,
        source: :system, provider_name: nil
      )
    end
  end
end
