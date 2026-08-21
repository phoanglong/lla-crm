require 'rails_helper'

RSpec.describe 'Firecrawl Webhooks', type: :request do
  describe 'POST /enterprise/webhooks/firecrawl?assistant_id=:assistant_id&token=:token' do
    let!(:account) { create(:account) }
    let!(:assistant) { create(:captain_assistant, account: account) }

    let(:payload_data) do
      {
        markdown: 'hello world',
        metadata: { sourceURL: 'https://example.com', title: 'Example', ignored: 'not-forwarded' }
      }
    end

    let(:valid_token) { Lla::Captain::FirecrawlWebhookToken.generate(assistant) }

    context 'with valid token' do
      context 'with crawl.page event type' do
        let(:valid_params) do
          {
            type: 'crawl.page',
            data: [payload_data]
          }
        end

        it 'processes the webhook and returns success' do
          expect(Captain::Tools::FirecrawlParserJob).to receive(:perform_later)
            .with(
              assistant_id: assistant.id,
              payload: {
                markdown: 'hello world',
                metadata: { sourceURL: 'https://example.com', title: 'Example' }
              }
            )

          post(
            "/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
            params: valid_params,
            as: :json
          )
          expect(response).to have_http_status(:ok)
          expect(response.body).to be_empty
        end
      end

      context 'with crawl.completed event type' do
        let(:valid_params) do
          {
            type: 'crawl.completed'
          }
        end

        it 'returns success without enqueuing job' do
          expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

          post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
               params: valid_params,
               as: :json)

          expect(response).to have_http_status(:ok)
          expect(response.body).to be_empty
        end
      end
    end

    context 'with invalid token' do
      let(:invalid_params) do
        {
          type: 'crawl.page',
          data: [payload_data]
        }
      end

      it 'returns unauthorized status' do
        post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=invalid_token",
             params: invalid_params,
             as: :json)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with invalid assistant_id' do
      context 'with non-existent assistant_id' do
        it 'returns unauthorized status without disclosing assistant existence' do
          post("/enterprise/webhooks/firecrawl?assistant_id=invalid_id&token=#{valid_token}",
               params: { type: 'crawl.page', data: [payload_data] },
               as: :json)

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'with nil assistant_id' do
        it 'returns unauthorized status' do
          post("/enterprise/webhooks/firecrawl?token=#{valid_token}",
               params: { type: 'crawl.page', data: [payload_data] },
               as: :json)

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    context 'when the payload exceeds the page limit' do
      it 'returns payload too large without enqueuing jobs' do
        expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

        post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
             params: { type: 'crawl.page', data: Array.new(101, payload_data) }, as: :json)

        expect(response).to have_http_status(:content_too_large)
      end
    end
  end
end
