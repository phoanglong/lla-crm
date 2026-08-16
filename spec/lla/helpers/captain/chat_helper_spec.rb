# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ChatHelper do
  let(:private_input) { 'customer@example.test private account transcript' }
  let(:private_output) { 'private model answer with internal notes' }
  let(:attributes) { {} }
  let(:span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:account) { Struct.new(:id).new(42) }
  let(:recorder) do
    Class.new do
      include Captain::ChatHelper

      attr_reader :model

      def initialize(account, messages)
        @account = account
        @messages = messages
        @model = 'gpt-5.2'
        @run_id = 'safe-run-id'
        @tools = []
      end

      private

      def feature_name = 'copilot'
    end.new(account, [{ role: 'user', content: private_input }])
  end

  before do
    allow(span).to receive(:set_attribute) { |key, value| attributes[key] = value }
    allow(span).to receive(:finish)
  end

  it 'records only counts and byte sizes for the session input' do
    recorder.send(:apply_safe_session_attributes, span)

    serialized = attributes.to_json
    expect(serialized).to include('message_count', 'input_bytes', 'safe-run-id')
    expect(serialized).not_to include(private_input, 'customer@example.test')
  end

  it 'records tool argument counts and sizes but not attacker-controlled keys or values' do
    tool_call = Struct.new(:arguments).new({ query: private_input, token: 'sensitive-token' })

    summary = recorder.send(:safe_tool_input_summary, tool_call)

    expect(summary[:argument_count]).to eq(2)
    expect(summary.to_json).not_to include(private_input, 'sensitive-token', 'query', 'token')
  end

  it 'replaces an unregistered tool name before telemetry or progress persistence' do
    tool_call = Struct.new(:name).new(private_input)

    expect(recorder.send(:safe_tool_name, tool_call)).to eq('unknown')
  end

  it 'records generation metadata without prompt or model output content' do
    chat_message = Struct.new(:content).new(private_input)
    chat = Struct.new(:messages).new([chat_message, chat_message])
    model_message = Struct.new(:role, :content, :input_tokens, :output_tokens, :tool_calls)
                          .new('assistant', private_output, 12, 7, [])

    safe_attributes = recorder.send(:safe_generation_attributes, chat, model_message)

    serialized = safe_attributes.to_json
    expect(serialized).to include('message_count', 'input_bytes', 'output_bytes')
    expect(serialized).not_to include(private_input, private_output, 'customer@example.test')
  end
end
