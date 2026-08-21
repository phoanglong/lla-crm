# configuration related audited gem : https://github.com/collectiveidea/audited

Audited.config do |config|
  config.audit_class = ChatwootApp.lla? ? 'Lla::AuditLog' : 'Audited::Audit'
end
