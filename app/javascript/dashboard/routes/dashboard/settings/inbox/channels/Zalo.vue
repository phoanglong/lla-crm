<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const shouldBeBridgeUrl = (value = '') => {
  try {
    const url = new URL(value);
    return (
      url.protocol === 'https:' &&
      url.hostname.length > 0 &&
      !url.username &&
      !url.password
    );
  } catch {
    return false;
  }
};

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: 'Zalo OA',
      bridgeUrl:
        window.chatwootConfig?.zaloBridgeUrl || 'https://zbridge.llavn.cloud',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
    normalizedBridgeUrl() {
      return this.bridgeUrl.trim().replace(/\/$/, '');
    },
    authorizeUrl() {
      return `${this.normalizedBridgeUrl}/oauth/start`;
    },
  },
  validations: {
    channelName: { required },
    bridgeUrl: { shouldBeBridgeUrl },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const webhookUrl = `${this.normalizedBridgeUrl}/webhook/chatwoot`;
        const apiChannel = await this.$store.dispatch('inboxes/createChannel', {
          name: this.channelName?.trim(),
          channel: {
            type: 'api',
            webhook_url: webhookUrl,
            additional_attributes: {
              provider: 'zalo_oa',
              bridge_url: this.normalizedBridgeUrl,
            },
          },
        });

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: apiChannel.id,
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.ADD.ZALO_CHANNEL.API.ERROR_MESSAGE')
        );
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHANNEL_NAME.PLACEHOLDER')
            "
            @blur="v$.channelName.$touch"
          />
          <span v-if="v$.channelName.$error" class="message">{{
            $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHANNEL_NAME.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.bridgeUrl.$error }">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.BRIDGE_URL.LABEL') }}
          <input
            v-model="bridgeUrl"
            type="url"
            autocomplete="url"
            :placeholder="
              $t('INBOX_MGMT.ADD.ZALO_CHANNEL.BRIDGE_URL.PLACEHOLDER')
            "
            @blur="v$.bridgeUrl.$touch"
          />
          <span v-if="v$.bridgeUrl.$error" class="message">{{
            $t('INBOX_MGMT.ADD.ZALO_CHANNEL.BRIDGE_URL.ERROR')
          }}</span>
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.BRIDGE_URL.SUBTITLE') }}
        </p>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.AUTHORIZE_HELP') }}
          <a :href="authorizeUrl" target="_blank" rel="noopener noreferrer">
            {{ authorizeUrl }}
          </a>
        </p>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
