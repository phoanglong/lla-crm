# An explicit allowlist. The previous partial emitted `account_id`, `inbox_id` and
# `user_id` on every row — identifiers the caller already knows or has no business
# correlating — and the conversation timeline did not use a partial at all: it
# rendered the raw model, so any column added to `reporting_events` later would have
# started appearing in the API without anyone deciding that it should.
json.id reporting_event.id
json.name reporting_event.name
json.value reporting_event.value
json.value_in_business_hours reporting_event.value_in_business_hours
json.event_start_time reporting_event.event_start_time
json.event_end_time reporting_event.event_end_time
json.created_at reporting_event.created_at.to_i
json.conversation_id reporting_event.conversation_id
