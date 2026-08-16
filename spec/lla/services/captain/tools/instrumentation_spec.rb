# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Tools::Instrumentation do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, :administrator, account: account) }
  let!(:contact) { create(:contact, account: account, name: 'Private Customer', email: 'private@example.test') }
  let(:service) { Captain::Tools::Copilot::SearchContactsService.new(assistant, user: user) }
  let(:captured_attributes) { [] }
  let(:tracer) { instance_double(OpenTelemetry::Trace::Tracer, start_span: span) }
  let(:span) do
    instance_double(OpenTelemetry::Trace::Span).tap do |value|
      allow(value).to receive(:set_attribute) { |_key, attribute| captured_attributes << attribute.to_s }
      allow(value).to receive(:finish)
    end
  end

  before do
    allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)
    allow(OpentelemetryConfig).to receive(:tracer).and_return(tracer)
  end

  it 'records only argument names and byte counts, never tool input or output content' do
    result = service.execute(email: contact.email)

    expect(result).to include('Private Customer', 'private@example.test')
    expect(ChatwootApp).to have_received(:otel_enabled?)
    expect(tracer).to have_received(:start_span)
    expect(captured_attributes.join).to include('argument_names', 'input_bytes', 'output_bytes')
    expect(captured_attributes.join).not_to include('Private Customer', 'private@example.test')
    expect(span).to have_received(:finish)
  end
end
