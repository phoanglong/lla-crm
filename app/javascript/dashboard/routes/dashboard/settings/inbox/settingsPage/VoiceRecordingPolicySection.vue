<script>
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import NextInput from 'dashboard/components-next/input/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const DEFAULT_DISCLOSURE_VERSION = 'lla-voice-v1';
const DISCLOSURE_VERSION_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;

export default {
  components: {
    SettingsToggleSection,
    NextInput,
    NextButton,
    Spinner,
  },
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      recordingEnabled: this.inbox.voice_recording_enabled || false,
      disclosureVersion:
        this.inbox.voice_recording_disclosure_version ||
        DEFAULT_DISCLOSURE_VERSION,
      isUpdating: false,
    };
  },
  computed: {
    normalizedDisclosureVersion() {
      return this.disclosureVersion.trim();
    },
    disclosureVersionChanged() {
      return (
        this.normalizedDisclosureVersion !==
        (this.inbox.voice_recording_disclosure_version || '')
      );
    },
    canSaveDisclosureVersion() {
      return (
        this.recordingEnabled &&
        !this.isUpdating &&
        this.disclosureVersionChanged &&
        DISCLOSURE_VERSION_PATTERN.test(this.normalizedDisclosureVersion)
      );
    },
  },
  watch: {
    'inbox.voice_recording_enabled'(value) {
      this.recordingEnabled = value || false;
    },
    'inbox.voice_recording_disclosure_version'(value) {
      this.disclosureVersion = value || DEFAULT_DISCLOSURE_VERSION;
    },
  },
  methods: {
    async handleRecordingToggle(newValue) {
      if (this.isUpdating) return;

      const previousValue = this.recordingEnabled;
      this.recordingEnabled = newValue;
      this.isUpdating = true;
      try {
        const version = newValue
          ? this.disclosureVersion.trim() || DEFAULT_DISCLOSURE_VERSION
          : null;
        await InboxesAPI.setVoiceRecording(this.inbox.id, newValue, version);
        await this.$store.dispatch('inboxes/get', this.inbox.id);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (_) {
        this.recordingEnabled = previousValue;
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdating = false;
      }
    },
    async saveDisclosureVersion() {
      if (!this.canSaveDisclosureVersion) return;

      this.isUpdating = true;
      try {
        await InboxesAPI.setVoiceRecording(
          this.inbox.id,
          true,
          this.normalizedDisclosureVersion
        );
        await this.$store.dispatch('inboxes/get', this.inbox.id);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (_) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdating = false;
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col gap-4">
    <div
      class="relative"
      :class="{ 'pointer-events-none opacity-60': isUpdating }"
    >
      <SettingsToggleSection
        :model-value="recordingEnabled"
        :header="$t('INBOX_MGMT.VOICE_CONFIGURATION.RECORDING.LABEL')"
        :description="
          $t('INBOX_MGMT.VOICE_CONFIGURATION.RECORDING.DESCRIPTION')
        "
        :hide-toggle="isUpdating"
        @update:model-value="handleRecordingToggle"
      >
        <template v-if="isUpdating" #hiddenToggle>
          <Spinner class="size-4 text-n-slate-11" />
        </template>
      </SettingsToggleSection>
    </div>

    <NextInput
      v-if="recordingEnabled"
      v-model="disclosureVersion"
      :label="$t('INBOX_MGMT.VOICE_CONFIGURATION.RECORDING.VERSION_LABEL')"
      :help-text="
        $t('INBOX_MGMT.VOICE_CONFIGURATION.RECORDING.VERSION_HELP_TEXT')
      "
      :disabled="isUpdating"
      :maxlength="64"
    />

    <div v-if="recordingEnabled">
      <NextButton
        :disabled="!canSaveDisclosureVersion"
        :is-loading="isUpdating"
        :label="$t('INBOX_MGMT.VOICE_CONFIGURATION.RECORDING.SAVE_VERSION')"
        @click="saveDisclosureVersion"
      />
    </div>
  </div>
</template>
