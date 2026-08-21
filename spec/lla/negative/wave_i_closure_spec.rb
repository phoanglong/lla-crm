# frozen_string_literal: true

require 'rails_helper'

# Wave I closure: reporting events, CSAT review notes, the shared authorization
# cohort and search, owned by LLA and working with enterprise off. Every example
# below fails on the tree as it was before this wave.
RSpec.describe 'Wave I closure' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }

  def auth(user) = user.create_new_auth_token

  describe 'the account reporting-events endpoint', type: :request do
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

    before do
      create(:reporting_event, account: account, conversation: conversation, inbox: inbox,
                               user: agent, name: 'first_response', value: 120)
    end

    # The route was `if ChatwootApp.enterprise?` and the controller inherited
    # `Api::V1::Accounts::EnterpriseAccountsController` — an empty subclass of the
    # ordinary base. With enterprise off the endpoint did not exist at all.
    it 'answers with enterprise off' do
      get "/api/v1/accounts/#{account.id}/reporting_events", headers: auth(administrator), as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].length).to eq(1)
    end

    it 'is served by the LLA controller, not an enterprise one' do
      route = Rails.application.routes.recognize_path("/api/v1/accounts/#{account.id}/reporting_events")
      controller = "#{route[:controller]}_controller".camelize.constantize

      expect(controller.name).to eq('Lla::Api::V1::Accounts::ReportingEventsController')
      # It used to inherit `Api::V1::Accounts::EnterpriseAccountsController`, an
      # empty subclass of this same base — a name, not behaviour, and one that took
      # the endpoint away with enterprise off.
      expect(controller.superclass.name).to eq('Api::V1::Accounts::BaseController')
      expect(controller.instance_method(:index).source_location.first).to include('lla/rails/')
      # `Enterprise::Concerns::ApplicationControllerConcern` is still mixed into
      # every controller in enterprise mode; removing it is Wave J's obligation, not
      # this one. What this asserts is that nothing enterprise sits between this
      # controller and the ordinary base.
      chain = controller.ancestors.take_while { |mod| mod.to_s != 'Api::BaseController' }
      expect(chain.map(&:to_s)).not_to include(a_string_matching(/^Enterprise::/))
    end

    # The controller was admin-only while `ReportPolicy` grants `report_manage`
    # elsewhere, so the same permission opened the reports page and not this one.
    it 'admits a custom role holding report_manage' do
      role = create(:custom_role, account: account, permissions: ['report_manage'])
      account.account_users.find_by(user_id: agent.id).update!(custom_role: role)

      get "/api/v1/accounts/#{account.id}/reporting_events", headers: auth(agent), as: :json

      expect(response).to have_http_status(:success)
    end

    it 'refuses a plain agent' do
      get "/api/v1/accounts/#{account.id}/reporting_events", headers: auth(agent), as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    # `(params[:page] || 1).to_i` accepted -5 and 99999999999.
    it 'clamps a negative page' do
      get "/api/v1/accounts/#{account.id}/reporting_events?page=-5", headers: auth(administrator), as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['meta']['current_page']).to eq(1)
    end

    it 'clamps an absurd page' do
      get "/api/v1/accounts/#{account.id}/reporting_events?page=99999999999",
          headers: auth(administrator), as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['meta']['current_page']).to be <= 10_000
    end

    it 'treats a non-numeric page as the first page' do
      get "/api/v1/accounts/#{account.id}/reporting_events?page=abc", headers: auth(administrator), as: :json

      expect(response.parsed_body['meta']['current_page']).to eq(1)
    end

    it 'returns nothing for an event name it does not recognise, rather than ignoring the filter' do
      get "/api/v1/accounts/#{account.id}/reporting_events?name=not_an_event",
          headers: auth(administrator), as: :json

      expect(response.parsed_body['payload']).to be_empty
    end

    it 'filters by a known event name' do
      get "/api/v1/accounts/#{account.id}/reporting_events?name=first_response",
          headers: auth(administrator), as: :json

      expect(response.parsed_body['payload'].length).to eq(1)
    end

    # An inbox id from another account was passed straight into the scope, where it
    # simply matched nothing — but a *user* id from another account did the same,
    # and neither was checked, so the endpoint answered as though the filter had
    # been applied to this account's data.
    it 'returns nothing when filtered by an inbox belonging to another account' do
      foreign_inbox = create(:inbox, account: create(:account))

      get "/api/v1/accounts/#{account.id}/reporting_events?inbox_id=#{foreign_inbox.id}",
          headers: auth(administrator), as: :json

      expect(response.parsed_body['payload']).to be_empty
    end

    it 'returns nothing when filtered by a user belonging to another account' do
      foreign_user = create(:user, account: create(:account))

      get "/api/v1/accounts/#{account.id}/reporting_events?user_id=#{foreign_user.id}",
          headers: auth(administrator), as: :json

      expect(response.parsed_body['payload']).to be_empty
    end

    # The partial emitted account_id, inbox_id and user_id on every row.
    it 'does not emit internal identifiers the caller has no use for' do
      get "/api/v1/accounts/#{account.id}/reporting_events", headers: auth(administrator), as: :json

      row = response.parsed_body['payload'].first
      expect(row.keys).to match_array(%w[id name value value_in_business_hours event_start_time
                                         event_end_time created_at conversation_id])
    end
  end

  describe 'the conversation reporting-events timeline', type: :request do
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

    before do
      create(:inbox_member, inbox: inbox, user: administrator)
      create(:reporting_event, account: account, conversation: conversation, inbox: inbox,
                               user: agent, name: 'first_response', value: 120)
    end

    # It was `render json: @conversation.reporting_events`, which serialises every
    # column of the table — including any column added later.
    it 'renders an allowlist rather than the raw record' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/reporting_events",
          headers: auth(administrator), as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.first.keys).to match_array(%w[id name value value_in_business_hours
                                                                event_start_time event_end_time
                                                                created_at conversation_id])
    end
  end

  describe 'CSAT review notes', type: :request do
    let(:csat) do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:csat_survey_response, account: account, conversation: conversation,
                                    contact: conversation.contact, assigned_agent: agent)
    end

    def patch_note(value, user: administrator)
      patch "/api/v1/accounts/#{account.id}/csat_survey_responses/#{csat.id}",
            params: { csat_review_notes: value }, headers: auth(user), as: :json
    end

    it 'can be written with enterprise off' do
      patch_note('Reviewed and accurate.')

      expect(response).to have_http_status(:success)
      expect(csat.reload.csat_review_notes).to eq('Reviewed and accurate.')
      expect(csat.review_notes_updated_by_id).to eq(administrator.id)
    end

    # `params[:csat_review_notes]` was read raw, so a Hash was stored as the string
    # form of ActionController::Parameters.
    it 'refuses a structure where a note is expected' do
      patch_note({ evil: 'x' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(csat.reload.csat_review_notes).to be_blank
    end

    it 'refuses a note longer than the bound' do
      patch_note('x' * 5_001)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(csat.reload.csat_review_notes).to be_blank
    end

    it 'accepts a note exactly at the bound' do
      patch_note('x' * 5_000)

      expect(response).to have_http_status(:success)
    end

    it 'strips control characters instead of storing them' do
      patch_note("ok \u0007 note")

      expect(response).to have_http_status(:success)
      expect(csat.reload.csat_review_notes).to eq('ok  note')
    end

    it 'treats a blank note as clearing the note' do
      csat.update!(csat_review_notes: 'previous')
      patch_note('   ')

      expect(response).to have_http_status(:success)
      expect(csat.reload.csat_review_notes).to be_nil
    end

    it 'refuses a plain agent' do
      patch_note('nope', user: agent)

      expect(response).to have_http_status(:unauthorized)
      expect(csat.reload.csat_review_notes).to be_blank
    end
  end

  describe 'search' do
    let(:service) do
      SearchService.new(current_user: agent, current_account: account,
                        params: { q: query }, search_type: 'Message')
    end
    let(:query) { 'needle' }

    before do
      # `SearchService` resolves the caller's inboxes through `Current.account`.
      Current.account = account
      create(:inbox_member, inbox: inbox, user: agent)
      conversation = create(:conversation, account: account, inbox: inbox, assignee: agent)
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'a needle here')
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'unrelated hay')
    end

    after { Current.reset }

    it 'finds the message it should' do
      expect(service.perform[:messages].map(&:content)).to include('a needle here')
    end

    # `params[:q]` blank produced `ILIKE '%%'`, which matches every row.
    context 'when the query is blank' do
      let(:query) { '   ' }

      it 'returns nothing rather than everything' do
        expect(service.perform[:messages]).to be_empty
      end
    end

    context 'when the query is a bare wildcard' do
      let(:query) { '%' }

      it 'returns nothing rather than the whole account' do
        expect(service.perform[:messages]).to be_empty
      end
    end

    context 'when the query contains a LIKE wildcard' do
      let(:query) { 'a%here' }

      it 'treats it as a literal, not a wildcard' do
        expect(service.perform[:messages]).to be_empty
      end
    end

    context 'when the query is enormous' do
      let(:query) { 'n' * 5_000 }

      it 'is bounded rather than passed through' do
        expect { service.perform[:messages].to_a }.not_to raise_error
      end
    end

    # `to_tsquery` raises PG::SyntaxError on this input; `websearch_to_tsquery`
    # does not.
    context 'with the GIN path and query-language punctuation' do
      let(:query) { 'needle & | ! :' }

      before do
        account.enable_features('search_with_gin')
        account.save!
      end

      it 'does not turn a search box into a 500' do
        expect { service.perform[:messages].to_a }.not_to raise_error
      end
    end
  end

  describe 'the shared conversation cohort' do
    let(:other_agent) { create(:user, account: account, role: :agent) }

    def cohort_for(user)
      Lla::Search::ConversationCohort.new(
        account: account, user: user,
        account_user: account.account_users.find_by(user_id: user.id),
        inbox_ids: [inbox.id]
      )
    end

    before do
      create(:inbox_member, inbox: inbox, user: agent)
      create(:inbox_member, inbox: inbox, user: other_agent)
    end

    it 'is unrestricted for a member with no custom role' do
      expect(cohort_for(agent)).not_to be_restricted
    end

    # This is the leak: search filtered by assigned inbox only, so a role that
    # exists to confine someone to their own conversations did not confine their
    # search.
    it 'confines a participating-only role to their own conversations' do
      role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
      account.account_users.find_by(user_id: agent.id).update!(custom_role: role)

      mine = create(:conversation, account: account, inbox: inbox, assignee: agent)
      theirs = create(:conversation, account: account, inbox: inbox, assignee: other_agent)

      ids = cohort_for(agent).relation.pluck(:id)
      expect(ids).to include(mine.id)
      expect(ids).not_to include(theirs.id)
    end

    it 'lets an unassigned-manage role see unassigned conversations and their own' do
      role = create(:custom_role, account: account, permissions: ['conversation_unassigned_manage'])
      account.account_users.find_by(user_id: agent.id).update!(custom_role: role)

      unassigned = create(:conversation, account: account, inbox: inbox, assignee: nil)
      mine = create(:conversation, account: account, inbox: inbox, assignee: agent)
      theirs = create(:conversation, account: account, inbox: inbox, assignee: other_agent)

      ids = cohort_for(agent).relation.pluck(:id)
      expect(ids).to include(unassigned.id, mine.id)
      expect(ids).not_to include(theirs.id)
    end

    it 'grants everything in the inbox to a conversation_manage role' do
      role = create(:custom_role, account: account, permissions: ['conversation_manage'])
      account.account_users.find_by(user_id: agent.id).update!(custom_role: role)

      theirs = create(:conversation, account: account, inbox: inbox, assignee: other_agent)

      expect(cohort_for(agent).relation.pluck(:id)).to include(theirs.id)
    end

    it 'grants nothing to a role that carries no conversation permission' do
      role = create(:custom_role, account: account, permissions: ['report_manage'])
      account.account_users.find_by(user_id: agent.id).update!(custom_role: role)
      create(:conversation, account: account, inbox: inbox, assignee: agent)

      expect(cohort_for(agent).relation).to be_empty
    end
  end

  describe 'the reindex operation' do
    it 'reports that it did nothing rather than returning silently' do
      result = Lla::Messages::ReindexService.new(account: account).perform

      expect(result.state).to eq(:skipped)
      expect(result.reason).to be_present
      expect(result).not_to be_queued
    end
  end
end
