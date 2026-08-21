# frozen_string_literal: true

class Lla::Knowledge::GenerationCancellationService
  def initialize(account:, operation_id:)
    @operation = account.lla_knowledge_generation_operations.find(operation_id)
  end

  def perform
    Lla::Knowledge::GenerationStateService.new(@operation).terminalize!(
      state: 'cancelled', error_code: 'cancelled_by_user'
    )
  end
end
