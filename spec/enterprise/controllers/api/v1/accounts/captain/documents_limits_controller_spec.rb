require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Documents', type: :request do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:captain_limits) do
    {
      :startups => { :documents => 1, :responses => 100 }
    }.with_indifferent_access
  end

  # Hạn mức tài liệu theo gói nằm ở lớp quota EE (chuyển về LLA ở wave E5) —
  # phần spec này chạy ở chế độ EE ON cho tới lúc đó.
  describe 'POST /api/v1/accounts/:account_id/captain/documents' do
    let(:valid_attributes) do
      {
        document: {
          name: 'Test Document',
          external_link: 'https://example.com/doc',
          assistant_id: assistant.id
        }
      }
    end

    context 'when it is an admin' do
      context 'with limits exceeded' do
        before do
          create_list(:captain_document, 5, assistant: assistant, account: account)

          InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_CLOUD_PLAN_LIMITS').update!(value: captain_limits.to_json)
          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: valid_attributes,
               headers: admin.create_new_auth_token
        end

        it 'returns an error' do
          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end
  end
end
