# frozen_string_literal: true

# Compatibility facade backed by durable tenant-scoped operation records.
class Onboarding::HelpCenterGenerationState
  class Missing < StandardError; end

  SAFE_SKIP_CODE = /\Alla_knowledge_[a-z0-9_]{3,66}\z/

  class << self
    def current(id, account:)
      operation = account.lla_knowledge_generation_operations.find_by(id: id)
      return if operation.blank?

      Lla::Knowledge::GenerationStateService.new(operation).status.stringify_keys
    end

    def skip(id, account:, reason: nil)
      operation = account.lla_knowledge_generation_operations.find_by(id: id)
      raise Missing, 'knowledge generation state is missing' if operation.blank?

      Lla::Knowledge::GenerationStateService.new(operation).terminalize!(
        state: 'skipped', error_code: stable_code(reason)
      )
    end

    private

    def stable_code(reason)
      code = reason.to_s
      SAFE_SKIP_CODE.match?(code) ? code : 'generation_skipped'
    end
  end
end
