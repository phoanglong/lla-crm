require 'rails_helper'

RSpec.describe 'Enterprise Audit API', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }

  describe 'GET /api/v1/accounts/{account.id}/audit_logs' do
    context 'when it is an un-authenticated user' do
      it 'does not fetch audit logs associated with the account' do
        get "/api/v1/accounts/#{account.id}/audit_logs",
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated normal user' do
      let(:user) { create(:user, account: account) }

      it 'fetches audit logs associated with the account' do
        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: user.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    # check for response in parse
    context 'when it is an authenticated admin user' do
      it 'returns empty array if feature is not enabled' do
        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response['audit_logs']).to eql([])
      end

      it 'fetches audit logs associated with the account' do
        account.enable_features(:audit_logs)
        account.save!

        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response['audit_logs'][1]['auditable_type']).to eql('Inbox')
        expect(json_response['audit_logs'][1]['action']).to eql('create')
        expect(json_response['audit_logs'][1]['audited_changes']['name']).to eql(inbox.name)
        expect(json_response['audit_logs'][1]['associated_id']).to eql(account.id)
        # contains audit log for account user as well
        # contains audit logs for account update(enable audit logs)
        expect(json_response.slice('current_page', 'per_page', 'total_entries')).to eql(
          'current_page' => 1,
          'per_page' => 25,
          'total_entries' => 3
        )
      end
    end
  end

  # `auditlogs/Index.vue` renders this through `messageTimestamp`, which is
  # `fromUnixTime`. An ISO string there becomes an Invalid Date and `format`
  # raises `RangeError: Invalid time value`, taking the whole table with it.
  describe 'the created_at contract the audit log table reads' do
    it 'serialises created_at as unix seconds' do
      account.enable_features!(:audit_logs)
      inbox.update!(name: 'renamed so there is something to audit')

      get "/api/v1/accounts/#{account.id}/audit_logs",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      logs = JSON.parse(response.body)['audit_logs']
      expect(logs).not_to be_empty
      expect(logs.first['created_at']).to be_a(Integer)
    end
  end
end
