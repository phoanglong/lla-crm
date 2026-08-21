const attestationId = () =>
  window.crypto?.randomUUID?.() ||
  `recording-${Date.now()}-${Math.random().toString(36).slice(2)}`;

export const requestVoiceRecordingConsent = ({ inbox, t }) => {
  if (!inbox?.voice_recording_enabled) return null;

  const disclosureVersion = inbox.voice_recording_disclosure_version;
  if (!disclosureVersion) return null;

  // Native confirmation keeps the attestation synchronous across every call entry point.
  // eslint-disable-next-line no-alert
  const accepted = window.confirm(
    t('INBOX_MGMT.VOICE_CONFIGURATION.RECORDING.ATTESTATION_PROMPT', {
      version: disclosureVersion,
    })
  );
  if (!accepted) return null;

  return {
    accepted: true,
    attestation_id: attestationId(),
    attested_at: new Date().toISOString(),
    disclosure_version: disclosureVersion,
    method: 'agent_attestation',
  };
};
