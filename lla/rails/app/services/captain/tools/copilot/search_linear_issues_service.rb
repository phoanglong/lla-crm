# frozen_string_literal: true

class Captain::Tools::Copilot::SearchLinearIssuesService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'search_linear_issues'
  end

  description 'Search Linear issues based on a search term'
  param :term, type: :string, desc: 'The search term to find Linear issues', required: true

  def execute(term:)
    return 'Linear integration is not enabled' unless active?

    safe_term = bounded_query(term)
    return 'Please provide a more specific Linear search term' unless meaningful_query?(safe_term)

    format_search_result(search_issues(safe_term))
  rescue StandardError => e
    Rails.logger.warn("LLA Linear search failed account_id=#{assistant&.account_id} error=#{e.class.name}")
    'Linear search unavailable'
  end

  def active?
    administrator? && assistant.account.feature_enabled?('linear_integration') &&
      assistant.account.hooks.exists?(app_id: 'linear', status: :enabled)
  end

  private

  def search_issues(term)
    result = Integrations::Linear::ProcessorService.new(account: assistant.account).search_issue(term)
    return if result[:error]

    Array(result[:data]).first(MAX_RESULT_COUNT)
  end

  def format_search_result(issues)
    return 'Linear search unavailable' if issues.nil?
    return 'No issues found, I should try another similar search term' if issues.empty?

    content = "Total number of issues: #{issues.length}\n#{issues.map { |issue| format_issue(issue) }.join("\n---\n")}"
    bounded_output("<linear_issues_data>\n#{content}\n</linear_issues_data>")
  end

  def format_issue(issue)
    <<~ISSUE
      Title: #{safe_field(issue['title'])}
      ID: #{safe_field(issue['id'])}
      State: #{safe_field(issue.dig('state', 'name'))}
      Priority: #{format_priority(issue['priority'])}
      Assignee: #{safe_field(issue.dig('assignee', 'name')).presence || 'Unassigned'}
      Description: #{safe_field(issue['description'])}
    ISSUE
  end

  def safe_field(value)
    value.to_s.scrub.byteslice(0, 2_048).to_s
  end

  def format_priority(priority)
    { 0 => 'No priority', 1 => 'Urgent', 2 => 'High', 3 => 'Medium', 4 => 'Low' }.fetch(priority, 'Unknown')
  end
end
