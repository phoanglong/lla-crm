# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla do
  let(:legacy_paths) do
    %w[
      enterprise/app/builders/captain/assistant_drilldown_builder.rb
      enterprise/app/builders/captain/assistant_stats_builder.rb
      enterprise/app/builders/captain/assistant_stats_window.rb
      enterprise/app/controllers/api/v1/accounts/captain/bulk_actions_controller.rb
      enterprise/app/controllers/api/v1/accounts/captain/message_reports_controller.rb
      enterprise/app/fields/captain_model_overrides_field.rb
      enterprise/app/finders/captain/faq_suggestion_finder.rb
      enterprise/app/helpers/captain/firecrawl_helper.rb
      enterprise/app/models/captain/message_report.rb
      enterprise/app/services/captain/tool_registry_service.rb
      enterprise/app/views/api/v1/accounts/captain/bulk_actions/create.json.jbuilder
      enterprise/app/views/api/v1/accounts/captain/message_reports/create.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_assistant_response.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_assistant.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_document.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_faq_observation.json.jbuilder
      enterprise/app/views/api/v1/models/captain/_faq_suggestion.json.jbuilder
      enterprise/app/views/fields/captain_model_overrides_field/_form.html.erb
      enterprise/app/views/fields/captain_model_overrides_field/_show.html.erb
      enterprise/lib/enterprise/captain/base_task_service.rb
    ]
  end

  let(:runtime_source_locations) do
    {
      stats_window: Captain::AssistantStatsWindow.instance_method(:current).source_location.first,
      stats_builder: Captain::AssistantStatsBuilder.instance_method(:metrics).source_location.first,
      drilldown_builder: Captain::AssistantDrilldownBuilder.instance_method(:build).source_location.first,
      bulk_controller: Api::V1::Accounts::Captain::BulkActionsController.instance_method(:create).source_location.first,
      feedback_controller: Api::V1::Accounts::Captain::MessageReportsController.instance_method(:create).source_location.first,
      model_field: CaptainModelOverridesField.instance_method(:feature_rows).source_location.first,
      feedback_model: Captain::MessageReport.instance_method(:message_contract).source_location.first,
      base_task_quota: Captain::BaseTaskService.instance_method(:perform).source_location.first,
      suggestion_scope: Api::V1::Accounts::Captain::FaqSuggestionsController.instance_method(:visible_suggestions).source_location.first,
      firecrawl_token: Lla::Captain::FirecrawlWebhookToken.method(:generate).source_location.first,
      agent_tools: Captain::Assistant.instance_method(:agent_tools).source_location.first
    }
  end

  let(:view_templates) do
    {
      assistant: ['api/v1/accounts/captain/assistants/assistant', true],
      document: ['api/v1/accounts/captain/documents/document', true],
      assistant_response: ['api/v1/accounts/captain/assistant_responses/assistant_response', true],
      faq_suggestion: ['api/v1/accounts/captain/faq_suggestions/faq_suggestion', true],
      faq_observation: ['api/v1/accounts/captain/faq_suggestions/show', false]
    }
  end

  it 'removes every path in the exact 20-file E5 Enterprise inventory' do
    expect(legacy_paths.length).to eq(20)
    expect(legacy_paths.select { |path| Rails.root.join(path).exist? }).to be_empty
  end

  it 'resolves every E5 runtime replacement from LLA-owned source' do
    expect(runtime_source_locations.values).to all(include('/lla/rails/'))
  end

  it 'does not retain the three obsolete alternate runtime constants' do
    expect(Captain.const_defined?(:FaqSuggestionFinder, false)).to be(false)
    expect(Captain.const_defined?(:FirecrawlHelper, false)).to be(false)
    expect(Captain.const_defined?(:ToolRegistryService, false)).to be(false)
  end

  it 'resolves the five replacement render paths from LLA-owned views' do
    lookup_context = ActionView::LookupContext.new(ActionController::Base.view_paths)
    identifiers = view_templates.values.map do |path, partial|
      lookup_context.find_template(path, [], partial, [], formats: [:json], handlers: [:jbuilder]).identifier
    end

    expect(identifiers).to all(include('/lla/rails/'))
  end
end
