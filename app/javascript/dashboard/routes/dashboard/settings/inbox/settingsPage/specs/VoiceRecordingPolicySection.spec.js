import { shallowMount } from '@vue/test-utils';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import VoiceRecordingPolicySection from '../VoiceRecordingPolicySection.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/inboxes', () => ({
  default: { setVoiceRecording: vi.fn(() => Promise.resolve()) },
}));

describe('VoiceRecordingPolicySection', () => {
  const dispatch = vi.fn(() => Promise.resolve());
  const mountComponent = (inbox = {}) =>
    shallowMount(VoiceRecordingPolicySection, {
      props: {
        inbox: {
          id: 7,
          voice_recording_enabled: true,
          voice_recording_disclosure_version: 'lla-voice-v1',
          ...inbox,
        },
      },
      global: {
        mocks: {
          $store: { dispatch },
          $t: key => key,
        },
      },
    });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('saves a new valid disclosure version and refreshes the inbox', async () => {
    const wrapper = mountComponent();
    await wrapper.setData({ disclosureVersion: 'lla-voice-v2' });

    await wrapper.vm.saveDisclosureVersion();

    expect(InboxesAPI.setVoiceRecording).toHaveBeenCalledWith(
      7,
      true,
      'lla-voice-v2'
    );
    expect(dispatch).toHaveBeenCalledWith('inboxes/get', 7);
    expect(useAlert).toHaveBeenCalledWith(
      'INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'
    );
  });

  it('does not submit malformed disclosure versions', async () => {
    const wrapper = mountComponent();
    await wrapper.setData({ disclosureVersion: 'not valid' });

    await wrapper.vm.saveDisclosureVersion();

    expect(wrapper.vm.canSaveDisclosureVersion).toBe(false);
    expect(InboxesAPI.setVoiceRecording).not.toHaveBeenCalled();
  });

  it('clears the disclosure version when recording is disabled', async () => {
    const wrapper = mountComponent();

    await wrapper.vm.handleRecordingToggle(false);

    expect(InboxesAPI.setVoiceRecording).toHaveBeenCalledWith(7, false, null);
    expect(dispatch).toHaveBeenCalledWith('inboxes/get', 7);
  });
});
