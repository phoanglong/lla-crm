<script>
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import TextArea from 'next/textarea/TextArea.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import VoiceRecordingPolicySection from './VoiceRecordingPolicySection.vue';

const effectiveCallingState = inbox => {
  if (inbox.calling_lifecycle_state === 'pending') {
    return inbox.calling_requested_enabled || false;
  }
  return inbox.provider_config?.calling_enabled || inbox.voice_enabled || false;
};

export default {
  components: {
    SettingsFieldSection,
    SettingsToggleSection,
    NextButton,
    TextArea,
    Spinner,
    VoiceRecordingPolicySection,
  },
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      callingEnabled: effectiveCallingState(this.inbox),
      callingLifecycleState: this.inbox.calling_lifecycle_state || 'ready',
      inboundCallsEnabled:
        this.inbox.provider_config?.inbound_calls_enabled !== false,
      permissionRequestBody:
        this.inbox.provider_config?.call_permission_request_body || '',
      isUpdating: false,
      isTogglingCalling: false,
      isTogglingInbound: false,
      lifecyclePollTimer: null,
    };
  },
  computed: {
    phoneNumber() {
      return (
        this.inbox.provider_config?.phone_number || this.inbox.phone_number
      );
    },
    isCallingTransitioning() {
      return this.isTogglingCalling || this.callingLifecycleState === 'pending';
    },
  },
  watch: {
    'inbox.provider_config.calling_enabled'(val) {
      if (this.callingLifecycleState !== 'pending') {
        this.callingEnabled = val || false;
      }
    },
    'inbox.calling_requested_enabled'(val) {
      if (this.callingLifecycleState === 'pending') {
        this.callingEnabled = val || false;
      }
    },
    'inbox.calling_lifecycle_state'(val) {
      this.callingLifecycleState = val || 'ready';
      if (this.callingLifecycleState !== 'pending') {
        this.callingEnabled = effectiveCallingState(this.inbox);
      }
    },
    'inbox.provider_config.call_permission_request_body'(val) {
      this.permissionRequestBody = val || '';
    },
    'inbox.provider_config.inbound_calls_enabled'(val) {
      this.inboundCallsEnabled = val !== false;
    },
  },
  beforeUnmount() {
    window.clearTimeout(this.lifecyclePollTimer);
  },
  methods: {
    scheduleLifecycleRefresh(attempt = 0) {
      window.clearTimeout(this.lifecyclePollTimer);
      if (attempt >= 10 || this.callingLifecycleState !== 'pending') return;

      this.lifecyclePollTimer = window.setTimeout(async () => {
        try {
          await this.$store.dispatch('inboxes/get', this.inbox.id);
        } catch (_) {
          // A transient refresh failure must not interrupt bounded polling.
        } finally {
          this.scheduleLifecycleRefresh(attempt + 1);
        }
      }, 2000);
    },
    async handleInboundToggle(newValue) {
      if (this.isTogglingInbound) return;
      const previousValue = this.inboundCallsEnabled;
      this.inboundCallsEnabled = newValue;
      this.isTogglingInbound = true;
      try {
        await InboxesAPI.setInboundCalls(this.inbox.id, newValue);
        await this.$store.dispatch('inboxes/get', this.inbox.id);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (_) {
        this.inboundCallsEnabled = previousValue;
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isTogglingInbound = false;
      }
    },
    async handleCallingToggle(newValue) {
      if (this.isTogglingCalling) return;
      const previousValue = this.callingEnabled;
      this.callingEnabled = newValue;
      this.isTogglingCalling = true;
      try {
        let lifecycleResponse;
        if (newValue) {
          lifecycleResponse = await InboxesAPI.enableWhatsappCalling(
            this.inbox.id
          );
        } else {
          lifecycleResponse = await InboxesAPI.disableWhatsappCalling(
            this.inbox.id
          );
        }
        await this.$store.dispatch('inboxes/get', this.inbox.id);
        this.callingLifecycleState =
          lifecycleResponse?.data?.calling_lifecycle_state ||
          this.inbox.calling_lifecycle_state ||
          'pending';
        this.scheduleLifecycleRefresh();
        useAlert(this.$t('INBOX_MGMT.WHATSAPP_CALLING.REQUEST_ACCEPTED'));
      } catch (_) {
        this.callingEnabled = previousValue;
        const fallbackMessage = newValue
          ? this.$t('INBOX_MGMT.WHATSAPP_CALLING.ENABLE_FAILED')
          : this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE');
        useAlert(fallbackMessage);
      } finally {
        this.isTogglingCalling = false;
      }
    },
    async updateCallingSettings() {
      this.isUpdating = true;
      try {
        await InboxesAPI.setWhatsappCallingMessage(
          this.inbox.id,
          this.permissionRequestBody.trim() || null
        );
        await this.$store.dispatch('inboxes/get', this.inbox.id);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        const message =
          error?.response?.data?.message ||
          this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE');
        useAlert(message);
      } finally {
        this.isUpdating = false;
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col gap-6">
    <div
      class="relative"
      :class="{ 'pointer-events-none opacity-60': isCallingTransitioning }"
    >
      <SettingsToggleSection
        :model-value="callingEnabled"
        :header="$t('INBOX_MGMT.WHATSAPP_CALLING.ENABLE.LABEL')"
        :description="$t('INBOX_MGMT.WHATSAPP_CALLING.ENABLE.DESCRIPTION')"
        :hide-toggle="isCallingTransitioning"
        @update:model-value="handleCallingToggle"
      >
        <template v-if="isCallingTransitioning" #hiddenToggle>
          <Spinner class="size-4 text-n-slate-11" />
        </template>
      </SettingsToggleSection>
      <p
        v-if="callingLifecycleState === 'failed'"
        class="mt-2 text-sm text-n-ruby-11"
      >
        {{ $t('INBOX_MGMT.WHATSAPP_CALLING.LIFECYCLE_FAILED') }}
      </p>
    </div>

    <template v-if="callingEnabled">
      <div
        class="relative"
        :class="{ 'pointer-events-none opacity-60': isTogglingInbound }"
      >
        <SettingsToggleSection
          :model-value="inboundCallsEnabled"
          :header="$t('INBOX_MGMT.VOICE_CONFIGURATION.INBOUND.LABEL')"
          :description="
            $t('INBOX_MGMT.VOICE_CONFIGURATION.INBOUND.DESCRIPTION')
          "
          :hide-toggle="isTogglingInbound"
          @update:model-value="handleInboundToggle"
        >
          <template v-if="isTogglingInbound" #hiddenToggle>
            <Spinner class="size-4 text-n-slate-11" />
          </template>
        </SettingsToggleSection>
      </div>

      <SettingsFieldSection
        v-if="phoneNumber"
        :label="$t('INBOX_MGMT.WHATSAPP_CALLING.PHONE_NUMBER.LABEL')"
        :help-text="$t('INBOX_MGMT.WHATSAPP_CALLING.PHONE_NUMBER.HELP_TEXT')"
      >
        <woot-code :script="phoneNumber" lang="html" />
      </SettingsFieldSection>

      <SettingsFieldSection
        :label="$t('INBOX_MGMT.WHATSAPP_CALLING.PERMISSION_REQUEST_BODY.LABEL')"
        :help-text="
          $t('INBOX_MGMT.WHATSAPP_CALLING.PERMISSION_REQUEST_BODY.HELP_TEXT')
        "
      >
        <TextArea
          v-model="permissionRequestBody"
          :placeholder="
            $t(
              'INBOX_MGMT.WHATSAPP_CALLING.PERMISSION_REQUEST_BODY.PLACEHOLDER'
            )
          "
          auto-height
          resize
        />
      </SettingsFieldSection>

      <SettingsFieldSection
        :label="$t('INBOX_MGMT.WHATSAPP_CALLING.HOW_IT_WORKS.LABEL')"
        :help-text="$t('INBOX_MGMT.WHATSAPP_CALLING.HOW_IT_WORKS.DESCRIPTION')"
      />

      <VoiceRecordingPolicySection :inbox="inbox" />

      <div>
        <NextButton
          :is-loading="isUpdating"
          :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
          @click="updateCallingSettings"
        />
      </div>
    </template>
  </div>
</template>
