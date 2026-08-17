# frozen_string_literal: true

class Lla::CustomDomains::OperationDispatchJob < ApplicationJob
  queue_as :low

  # The claim is what makes a duplicate enqueue harmless: only one worker can move
  # an operation out of `pending`, and the lease token it returns is the only thing
  # that lets that worker finalize later.
  def perform(operation_id)
    operation = Lla::CustomDomains::Operation.find_by(id: operation_id)
    return if operation.blank? || operation.terminal?

    lease = Lla::CustomDomains::OperationService.claim!(operation)
    return if lease.blank?

    Lla::CustomDomains::OperationExecutor.new(lease).perform
  end
end
