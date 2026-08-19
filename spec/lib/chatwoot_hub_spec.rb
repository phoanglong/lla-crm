require 'rails_helper'

describe ChatwootHub do
  describe '.base_url' do
    it 'uses the static hub url' do
      expect(described_class::DEFAULT_BASE_URL).to eq('https://hub.2.chatwoot.com')
      expect(described_class.base_url).to eq('https://hub.2.chatwoot.com')
    end
  end

  it 'generates installation identifier' do
    installation_identifier = described_class.installation_identifier
    expect(installation_identifier).not_to be_nil
    expect(described_class.installation_identifier).to eq installation_identifier
  end

  it 'reports the upstream compatibility version to Chatwoot Hub' do
    expect(described_class.instance_config).to include(
      installation_version: Rails.root.join('VERSION_CW').read.strip
    )
    expect(described_class.instance_config[:installation_version]).not_to eq(Rails.root.join('VERSION_LLA').read.strip)
  end

  context 'when fetching sync_with_hub' do
    after { ENV.delete('LLA_HUB_TELEMETRY_ENABLED') }

    it 'sends nothing at all unless the operator has enabled telemetry' do
      allow(RestClient).to receive(:post)
      expect(described_class.sync_with_hub).to be_nil
      expect(RestClient).not_to have_received(:post)
    end

    it 'get latest version from chatwoot hub' do
      version = '1.1.1'
      ENV['LLA_HUB_TELEMETRY_ENABLED'] = 'true'
      allow(RestClient).to receive(:post).and_return({ version: version }.to_json)
      expect(described_class.sync_with_hub['version']).to eq version
      expect(RestClient).to have_received(:post).with(described_class.ping_url, described_class.instance_config
        .merge(described_class.instance_metrics).to_json, { content_type: :json, accept: :json })
    end

    it 'will not send instance metrics when telemetry is disabled' do
      version = '1.1.1'
      with_modified_env DISABLE_TELEMETRY: 'true', LLA_HUB_TELEMETRY_ENABLED: 'true' do
        allow(RestClient).to receive(:post).and_return({ version: version }.to_json)
        expect(described_class.sync_with_hub['version']).to eq version
        expect(RestClient).to have_received(:post).with(described_class.ping_url,
                                                        described_class.instance_config.to_json, { content_type: :json, accept: :json })
      end
    end

    it 'returns nil when chatwoot hub is down' do
      with_modified_env LLA_HUB_TELEMETRY_ENABLED: 'true' do
        allow(RestClient).to receive(:post).and_raise(ExceptionList::REST_CLIENT_EXCEPTIONS.sample)
        expect(described_class.sync_with_hub).to be_nil
      end
    end
  end

  context 'when register instance' do
    let(:company_name) { 'test' }
    let(:owner_name) { 'test' }
    let(:owner_email) { 'test@test.com' }

    # Registration carries the owner's name and email address. It is off unless the
    # operator has said otherwise.
    after { ENV.delete('LLA_HUB_REGISTRATION_ENABLED') }

    it 'sends nothing unless registration is enabled' do
      allow(RestClient).to receive(:post)
      described_class.register_instance(company_name, owner_name, owner_email)
      expect(RestClient).not_to have_received(:post)
    end

    it 'sends info of registration' do
      info = { company_name: company_name, owner_name: owner_name, owner_email: owner_email, subscribed_to_mailers: true }
      ENV['LLA_HUB_REGISTRATION_ENABLED'] = 'true'
      allow(RestClient).to receive(:post)
      described_class.register_instance(company_name, owner_name, owner_email)
      expect(RestClient).to have_received(:post).with(described_class.registration_url,
                                                      info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
    end
  end

  context 'when sending events' do
    let(:event_name) { 'sample_event' }
    let(:event_data) { { 'sample_data' => 'sample_data' } }

    after { ENV.delete('LLA_HUB_TELEMETRY_ENABLED') }

    it 'sends nothing unless telemetry is enabled' do
      allow(RestClient).to receive(:post)
      described_class.emit_event(event_name, event_data)
      expect(RestClient).not_to have_received(:post)
    end

    it 'will send instance events' do
      info = { event_name: event_name, event_data: event_data }
      ENV['LLA_HUB_TELEMETRY_ENABLED'] = 'true'
      allow(RestClient).to receive(:post)
      described_class.emit_event(event_name, event_data)
      expect(RestClient).to have_received(:post).with(described_class.events_url,
                                                      info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
    end

    it 'will not send instance events when telemetry is disabled' do
      with_modified_env DISABLE_TELEMETRY: 'true', LLA_HUB_TELEMETRY_ENABLED: 'true' do
        info = { event_name: event_name, event_data: event_data }
        allow(RestClient).to receive(:post)
        described_class.emit_event(event_name, event_data)
        expect(RestClient).not_to have_received(:post)
          .with(described_class.events_url,
                info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
      end
    end
  end
end
