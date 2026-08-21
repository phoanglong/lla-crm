import { requestVoiceRecordingConsent } from '../useVoiceRecordingConsent';

describe('requestVoiceRecordingConsent', () => {
  const t = vi.fn(key => key);

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('does not prompt when the inbox recording policy is disabled', () => {
    const confirm = vi.spyOn(window, 'confirm');

    expect(requestVoiceRecordingConsent({ inbox: {}, t })).toBeNull();
    expect(confirm).not.toHaveBeenCalled();
  });

  it('continues without recording when the agent declines the attestation', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false);

    const result = requestVoiceRecordingConsent({
      inbox: {
        voice_recording_enabled: true,
        voice_recording_disclosure_version: 'lla-voice-v1',
      },
      t,
    });

    expect(result).toBeNull();
  });

  it('returns bounded evidence when the agent confirms the approved disclosure', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);

    const result = requestVoiceRecordingConsent({
      inbox: {
        voice_recording_enabled: true,
        voice_recording_disclosure_version: 'lla-voice-v1',
      },
      t,
    });

    expect(result).toMatchObject({
      accepted: true,
      disclosure_version: 'lla-voice-v1',
      method: 'agent_attestation',
    });
    expect(result.attestation_id).toMatch(/^[A-Za-z0-9_.:-]{8,128}$/);
    expect(new Date(result.attested_at).toString()).not.toBe('Invalid Date');
  });
});
