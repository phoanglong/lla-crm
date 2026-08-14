# configuration related audited gem : https://github.com/collectiveidea/audited

Audited.config do |config|
  config.audit_class = if ChatwootApp.lla?
                         'Lla::AuditLog'
                       elsif ChatwootApp.enterprise?
                         'Enterprise::AuditLog'
                       else
                         'Audited::Audit'
                       end
end
