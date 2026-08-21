# frozen_string_literal: true

require 'rails_helper'

# Waves J and K closure: the Chatwoot Cloud plane removed, the last of `enterprise/`
# gone, and the behaviour that had to survive reimplemented under LLA ownership.
RSpec.describe 'Wave J and K closure' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }

  describe 'the enterprise directory' do
    it 'does not exist' do
      expect(Rails.root.join('enterprise')).not_to exist
    end

    it 'leaves exactly one extension in the lookup chain' do
      expect(ChatwootApp.extensions).to eq(['lla'])
      expect(ChatwootApp.enterprise?).to be(false)
    end

    # These flags used to answer "does a folder exist on disk", which is not a
    # question about what the product can do.
    it 'no longer decides whether advanced search is possible by looking for a folder' do
      with_modified_env('OPENSEARCH_URL' => 'http://opensearch.invalid:9200') do
        expect(ChatwootApp.advanced_search_allowed?).to be(true)
      end
    end

    it 'still says no when there is no index configured' do
      with_modified_env('OPENSEARCH_URL' => nil) do
        expect(ChatwootApp.advanced_search_allowed?).to be(false)
      end
    end

    it 'keeps the capabilities that are LLA-owned' do
      expect(ChatwootApp.custom_roles?).to be(true)
      expect(ChatwootApp.sla?).to be(true)
      expect(ChatwootApp.voice_calls?).to be(true)
    end
  end

  describe 'the Chatwoot Cloud plane' do
    # Removed wholesale: Stripe commerce, Chatwoot Hub plan reconciliation, Clearbit
    # enrichment, Google marketing attribution, and the account-analysis scraper,
    # LLM evaluator and Discord notifier.
    %w[
      Enterprise::Billing::HandleStripeEventService
      Enterprise::Billing::Currencies
      Enterprise::CreateStripeCustomerJob
      Enterprise::ClearbitLookupService
      Internal::Accounts::MarketingAttributionService
      Internal::Accounts::MarketingConversionTrackingService
      Internal::AccountAnalysis::WebsiteScraperService
      Internal::AccountAnalysis::ThreatAnalyserService
      Internal::AccountAnalysis::DiscordNotifierService
      Internal::ReconcilePlanConfigService
      Firecrawl::Configuration
    ].each do |constant|
      it "no longer defines #{constant}" do
        expect { constant.constantize }.to raise_error(NameError)
      end
    end

    it 'has no commerce routes left to hit' do
      %w[
        /enterprise/api/v1/accounts/1/checkout
        /enterprise/api/v1/accounts/1/subscription
        /enterprise/api/v1/accounts/1/topup_checkout
        /enterprise/webhooks/stripe
      ].each do |path|
        expect { Rails.application.routes.recognize_path(path, method: :post) }
          .to raise_error(ActionController::RoutingError), "#{path} still routes"
      end
    end

    it 'keeps the firecrawl webhook, which is LLA-served' do
      expect(Rails.application.routes.recognize_path('/enterprise/webhooks/firecrawl', method: :post))
        .to include(controller: 'enterprise/webhooks/firecrawl')
    end
  end

  describe 'the Chatwoot hub' do
    # `sync_with_hub` posted instance metrics — account, user, inbox, conversation
    # and message counts — on a schedule. `register_instance` posted the owner's
    # company name, name and email at install time. `send_push` relayed every
    # mobile notification. None was opt-in. The capability was first gated, then
    # removed outright: there is no client left to switch on.
    it 'has no client, gate or switch' do
      expect(defined?(ChatwootHub)).to be_nil
      expect(defined?(Lla::Hub::EgressPolicy)).to be_nil
    end

    it 'no longer registers the installation, or the owner, at onboarding' do
      source = Rails.root.join('app/controllers/installation/onboarding_controller.rb').read

      expect(source).not_to match(/^\s*[^#]*register_instance/)
      expect(source).not_to include(':subscribe_to_updates')
    end

    it 'no longer relays mobile push through anybody' do
      expect(Notification::PushNotificationService.instance_methods(false).map(&:to_s))
        .not_to include('send_push_via_chatwoot_hub')
    end
  end

  describe 'entitlement' do
    # Six product capabilities were gated on `ChatwootHub.pricing_plan != 'community'`,
    # a value only Chatwoot's hosted hub writes. On an installation that never talks
    # to it, they were permanently off and no operator action could change that.
    it 'is premium by default, decided locally' do
      expect(Lla::Entitlements.plan).to eq('lla')
      expect(Lla::Entitlements.premium?).to be(true)
    end

    it 'can be set to community by the operator' do
      InstallationConfig.create!(name: Lla::Entitlements::PLAN_CONFIG_KEY, value: 'community')
      expect(Lla::Entitlements.premium?).to be(false)
    end

    it 'treats an unrecognised value as the default rather than as community' do
      InstallationConfig.create!(name: Lla::Entitlements::PLAN_CONFIG_KEY, value: 'nonsense')
      expect(Lla::Entitlements.plan).to eq('lla')
    end

    it 'decides the plan without a network call of any kind' do
      # WebMock refuses every non-local connection, so reaching an answer at all
      # is proof that nothing was asked of anybody.
      expect(Lla::Entitlements.plan).to eq('lla')
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'enables the capability cards that used to depend on a remote plan' do
      features = SuperAdmin::FeaturesHelper.available_features
      %w[custom_branding agent_capacity audit_logs disable_branding voice_calls].each do |key|
        expect(features[key]['enabled']).to be(true), "#{key} is still gated off"
      end
    end
  end

  describe 'conversation_required_attributes' do
    # Declared in the settings schema and permitted by the controller, but the
    # reader lived in an enterprise concern: writing it worked and reading it raised.
    it 'is readable and writable with enterprise off' do
      account.update!(settings: account.settings.merge('conversation_required_attributes' => %w[order_id]))

      expect(account.reload.conversation_required_attributes).to eq(%w[order_id])
    end

    it 'drops a key when the attribute it names is deleted' do
      definition = create(:custom_attribute_definition, account: account,
                                                        attribute_model: 'conversation_attribute',
                                                        attribute_key: 'order_id')
      account.update!(settings: account.settings.merge('conversation_required_attributes' => %w[order_id keep_me]))

      definition.destroy!

      expect(account.reload.conversation_required_attributes).to eq(%w[keep_me])
    end
  end

  describe 'account limits' do
    it 'honours the limits column for agents and inboxes' do
      account.update!(limits: { 'agents' => 3, 'inboxes' => 2 })

      expect(account.usage_limits[:agents]).to eq(3)
      expect(account.usage_limits[:inboxes]).to eq(2)
    end

    it 'falls back to no practical limit when nothing is configured' do
      expect(account.usage_limits[:agents]).to eq(ChatwootApp.max_limit)
    end

    # The `limits` column is free-form jsonb with a validation hook whose community
    # body is empty, so anything at all could be stored in it.
    it 'refuses a limit that is not a number' do
      account.limits = { 'agents' => 'lots' }

      expect(account).not_to be_valid
      expect(account.errors[:limits]).to be_present
    end

    it 'refuses a key that is not a limit' do
      account.limits = { 'something_else' => 3 }

      expect(account).not_to be_valid
    end

    it 'refuses to create an inbox past the account limit' do
      account.update!(limits: { 'inboxes' => 1 })
      create(:inbox, account: account)

      expect { create(:inbox, account: account) }
        .to raise_error(CustomExceptions::Inbox::LimitExceeded)
    end
  end

  describe 'custom roles' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }

    # The read side of custom roles is community code; the only place that wrote
    # `custom_role_id` was an enterprise extension, so with enterprise off a role
    # could be created and displayed but never assigned to anybody.
    it 'can be assigned to an agent through the API', type: :request do
      patch "/api/v1/accounts/#{account.id}/agents/#{agent.id}",
            params: { custom_role_id: role.id }, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(account.account_users.find_by(user_id: agent.id).custom_role_id).to eq(role.id)
    end

    it 'can be cleared again', type: :request do
      account.account_users.find_by(user_id: agent.id).update!(custom_role: role)

      patch "/api/v1/accounts/#{account.id}/agents/#{agent.id}",
            params: { custom_role_id: '' }, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(account.account_users.find_by(user_id: agent.id).custom_role_id).to be_nil
    end

    it 'refuses a role belonging to another account', type: :request do
      foreign = create(:custom_role, account: create(:account), permissions: ['conversation_manage'])

      patch "/api/v1/accounts/#{account.id}/agents/#{agent.id}",
            params: { custom_role_id: foreign.id }, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(account.account_users.find_by(user_id: agent.id).custom_role_id).to be_nil
    end
  end

  describe 'the audit trail' do
    let(:user) { create(:user, account: account, role: :administrator) }

    it 'records who made the change, not only their id' do
      entry = Lla::AuditLog.create!(auditable: account, action: 'update', user: user, audited_changes: { 'name' => %w[a b] })

      expect(entry.reload.username).to eq(user.email)
    end

    it 'audits a channel configuration change against its inbox' do
      inbox = create(:inbox, account: account)

      expect { inbox.channel.update!(website_url: 'https://example.invalid') }
        .to change { Lla::AuditLog.where(auditable_type: 'Inbox', auditable_id: inbox.id).count }.by(1)
    end

    # WhatsApp writes this column on a schedule. Auditing it buries the changes an
    # operator actually made.
    it 'does not audit a scheduled template-timestamp refresh' do
      channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)

      expect { channel.update!(message_templates_last_updated: Time.current) }
        .not_to(change { Lla::AuditLog.where(auditable_type: 'Inbox').count })
    end
  end

  describe 'reaching a contact on a voice inbox' do
    it 'offers a voice-enabled Twilio inbox as contactable' do
      contact = create(:contact, account: account, phone_number: '+84900000001')
      channel = create(:channel_twilio_sms, :with_phone_number, account: account, medium: :sms)
      channel.update!(voice_enabled: true)
      inbox = channel.inbox
      create(:inbox_member, inbox: inbox, user: create(:user, account: account))

      result = Contacts::ContactableInboxesService.new(contact: contact).get
      expect(result.map { |entry| entry[:inbox].id }).to include(inbox.id)
    end
  end

  describe 'SAML' do
    it 'answers whether an account authenticates through an identity provider' do
      expect(account.saml_enabled?).to be(false)
    end
  end
end
