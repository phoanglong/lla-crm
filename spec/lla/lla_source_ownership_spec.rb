# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla do
  let(:source_locations) do
    {
      messages_controller: Api::V1::Accounts::Captain::CopilotMessagesController.instance_method(:create).source_location.first,
      threads_controller: Api::V1::Accounts::Captain::CopilotThreadsController.instance_method(:create).source_location.first,
      chat_generation: Captain::ChatGenerationRecorder.instance_method(:record_llm_generation).source_location.first,
      chat_helper: Captain::ChatHelper.instance_method(:request_chat_completion).source_location.first,
      chat_response: Captain::ChatResponseHelper.instance_method(:build_response).source_location.first,
      response_job: Captain::Copilot::ResponseJob.instance_method(:perform).source_location.first,
      realtime_listener: ActionCableListener.instance_method(:copilot_message_created).source_location.first,
      chat_service: Captain::Copilot::ChatService.instance_method(:initialize).source_location.first,
      base_ai_service: Llm::BaseAiService.instance_method(:initialize).source_location.first,
      copilot_prompt: Captain::Llm::SystemPromptsService.method(:copilot_response_generator).source_location.first
    }
  end

  it 'owns every E4d Ruby runtime entry point in the LLA load path' do
    expect(source_locations.values).to all(include('/lla/rails/'))
  end

  it 'does not load the realtime extension more than once' do
    expect(ActionCableListener.ancestors.count { |ancestor| ancestor == Lla::ActionCableListener }).to eq(1)
  end

  it 'removes the superseded Enterprise runtime and view files' do
    legacy_paths = %w[
      enterprise/app/controllers/api/v1/accounts/captain/copilot_messages_controller.rb
      enterprise/app/controllers/api/v1/accounts/captain/copilot_threads_controller.rb
      enterprise/app/helpers/captain/chat_generation_recorder.rb
      enterprise/app/helpers/captain/chat_helper.rb
      enterprise/app/helpers/captain/chat_response_helper.rb
      enterprise/app/jobs/captain/copilot/response_job.rb
      enterprise/app/listeners/enterprise/action_cable_listener.rb
      enterprise/app/services/captain/copilot/chat_service.rb
      enterprise/app/services/llm/base_ai_service.rb
      enterprise/app/views/api/v1/accounts/captain/copilot_messages/create.json.jbuilder
      enterprise/app/views/api/v1/accounts/captain/copilot_messages/index.json.jbuilder
      enterprise/app/views/api/v1/accounts/captain/copilot_threads/create.json.jbuilder
      enterprise/app/views/api/v1/accounts/captain/copilot_threads/index.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_copilot_message.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_copilot_thread.json.jbuilder
    ]

    expect(legacy_paths.select { |path| Rails.root.join(path).exist? }).to be_empty
  end
end
