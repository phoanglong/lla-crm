json.audit_logs do
  json.array! @audit_logs do |audit_log|
    json.partial! 'api/v1/models/audit_log', formats: [:json], resource: audit_log
  end
end

json.current_page @audit_logs.current_page
json.per_page @audit_logs.limit_value
json.total_entries @audit_logs.total_count
