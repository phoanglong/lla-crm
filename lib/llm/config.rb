require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    # Một ngữ cảnh cho **một** lệnh gọi, dựng từ credential của đúng tenant đó. Cấu hình toàn
    # cục của tiến trình không bị chạm tới, nên hai tenant dùng hai nhà cung cấp khác nhau
    # trong cùng một tiến trình không đè lên nhau.
    def with_credential(credential)
      initialize!
      context = RubyLLM.context { |config| apply_credential(config, credential) }

      yield context
    end

    private

    # Mỗi nhà cung cấp có một cặp khoá cấu hình riêng trong ruby_llm; `openai_compatible` và
    # `azure_openai` nói giao thức OpenAI nên đi chung đường với OpenAI, chỉ khác endpoint.
    def apply_credential(config, credential)
      case credential.kind
      when 'anthropic'
        config.anthropic_api_key = credential.api_key
      when 'gemini'
        config.gemini_api_key = credential.api_key
      else
        config.openai_api_key = credential.api_key
        config.openai_api_base = credential.api_base.presence&.chomp('/')
      end
    end

    def configure_ruby_llm
      RubyLLM.configure do |config|
        config.openai_api_key = system_api_key if system_api_key.present?
        config.openai_api_base = openai_endpoint.chomp('/') if openai_endpoint.present?
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
        config.logger = Rails.logger
      end
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end
  end
end
