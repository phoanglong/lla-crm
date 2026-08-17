# frozen_string_literal: true

class Lla::CustomDomains::OperationDispatchJob < ApplicationJob
  queue_as :low

  # The claim is what makes a duplicate enqueue harmless: only one worker can move
  # an operation out of `pending`, everyone else exits without touching state.
  def perform(operation_id)
    operation = Lla::CustomDomains::Operation.find_by(id: operation_id)
    return if operation.blank? || operation.terminal?

    claimed = Lla::CustomDomains::OperationService.claim!(operation)
    return if claimed.blank?

    Lla::CustomDomains::OperationExecutor.new(claimed).perform
  end
end
