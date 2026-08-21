# frozen_string_literal: true

# Rebuild the search index for one account.
#
# The enterprise version returned silently when advanced search was unavailable, so
# an operator running a reindex on a system with no index configured saw success and
# nothing happened. It answers with a result now, and the caller reports it.
class Lla::Messages::ReindexService
  pattr_initialize [:account!]

  Result = Data.define(:account_id, :state, :reason) do
    def queued? = state == :queued
  end

  def perform
    return skipped('advanced_search_unavailable') unless ChatwootApp.advanced_search_allowed?
    return skipped('advanced_search_disabled_for_account') unless account.feature_enabled?('advanced_search')

    account.messages.reindex(mode: :async)
    Result.new(account_id: account.id, state: :queued, reason: nil)
  rescue StandardError => e
    # An index that is down must not take the operator's whole run with it.
    Rails.logger.warn("LLA_REINDEX_FAILED account=#{account.id} error=#{e.class.name}")
    Result.new(account_id: account.id, state: :failed, reason: e.class.name)
  end

  private

  def skipped(reason)
    Result.new(account_id: account.id, state: :skipped, reason: reason)
  end
end
