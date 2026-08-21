# frozen_string_literal: true

# Reindex operations, owned by LLA.
#
# The enterprise task printed "Reindex task queued" for every account regardless of
# what happened, including for accounts where nothing was queued at all, and it
# checked `OPENSEARCH_URL` itself rather than asking the service whether a reindex
# was possible. An operator reading the output could not tell a completed run from
# a run that did nothing. This one reports each account's actual outcome and exits
# non-zero if any account failed, so a scheduled run fails visibly.
namespace :lla do
  namespace :search do
    desc 'Reindex messages for every account'
    task reindex_all: :environment do
      results = Account.find_each.map { |account| reindex_lla_account(account) }
      report_lla_reindex(results)
    end

    desc 'Reindex messages for one account: rake lla:search:reindex_account ACCOUNT_ID=1'
    task reindex_account: :environment do
      account = Account.find_by(id: ENV.fetch('ACCOUNT_ID', nil))
      if account.nil?
        warn 'ACCOUNT_ID is missing or does not match an account'
        exit 1
      end
      report_lla_reindex([reindex_lla_account(account)])
    end
  end
end

def reindex_lla_account(account)
  result = Lla::Messages::ReindexService.new(account: account).perform
  puts "account=#{result.account_id} state=#{result.state}#{result.reason ? " reason=#{result.reason}" : ''}"
  result
end

def report_lla_reindex(results)
  by_state = results.group_by(&:state).transform_values(&:count)
  puts "queued=#{by_state[:queued].to_i} skipped=#{by_state[:skipped].to_i} failed=#{by_state[:failed].to_i}"
  exit 1 if by_state[:failed].to_i.positive?
end
