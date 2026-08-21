<script setup>
import { computed, onBeforeUnmount, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required, helpers } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import ZaloConnectionsAPI from 'dashboard/api/zaloConnections';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();
const router = useRouter();

const form = reactive({ name: 'Zalo OA', appId: '', appSecret: '', oaId: '' });
const rules = {
  name: { required },
  appId: { required, digits: helpers.regex(/^[0-9]{5,25}$/) },
  appSecret: { required },
};
const v$ = useVuelidate(rules, form);

const isCreating = ref(false);
const isChecking = ref(false);
const connection = ref(null);
const inbox = ref(null);
const checks = ref([]);
const requiredEvents = ref([]);
const copiedField = ref('');
const domain = reactive({
  value: '',
  code: '',
  result: null,
  isChecking: false,
});

let pollTimer = null;
// Người vận hành đang dán URL sang một tab khác; bắt họ bấm "kiểm tra lại" sau mỗi
// bước là bắt họ đoán khi nào Zalo đã gọi tới. Cứ tự hỏi cho tới khi xong.
const POLL_INTERVAL_MS = 5000;

const isConfigured = computed(() => Boolean(connection.value));
const checkFor = key => checks.value.find(check => check.key === key);
const isLive = computed(
  () =>
    Boolean(checkFor('oauth_authorized')?.ok) &&
    Boolean(checkFor('webhook_received')?.ok)
);

const applyPayload = payload => {
  connection.value = payload.connection;
  checks.value = payload.checks || [];
  requiredEvents.value = payload.required_events || [];
  if (payload.inbox) inbox.value = payload.inbox;
};

const stopPolling = () => {
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = null;
};
onBeforeUnmount(stopPolling);

const refreshStatus = async ({ silent = false } = {}) => {
  if (!connection.value) return;
  if (!silent) isChecking.value = true;
  try {
    const { data } = await ZaloConnectionsAPI.status(connection.value.id);
    applyPayload(data);
  } catch (error) {
    if (!silent) useAlert(error.message);
  } finally {
    isChecking.value = false;
  }
};

const createConnection = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  isCreating.value = true;
  try {
    const { data } = await ZaloConnectionsAPI.create({
      name: form.name.trim(),
      app_id: form.appId.trim(),
      app_secret: form.appSecret.trim(),
      oa_id: form.oaId.trim() || undefined,
    });
    applyPayload(data);
    // App Secret đã nằm ở cầu; không giữ lại bản sao nào trong bộ nhớ trình duyệt.
    form.appSecret = '';
    pollTimer = setInterval(
      () => refreshStatus({ silent: true }),
      POLL_INTERVAL_MS
    );
  } catch (error) {
    useAlert(
      error.response?.data?.error ||
        error.message ||
        t('INBOX_MGMT.ADD.ZALO_CHANNEL.API.ERROR_MESSAGE')
    );
  } finally {
    isCreating.value = false;
  }
};

const copy = async (field, value) => {
  await copyTextToClipboard(value);
  copiedField.value = field;
};

const checkDomain = async () => {
  domain.isChecking = true;
  domain.result = null;
  try {
    const { data } = await ZaloConnectionsAPI.checkDomain({
      domain: domain.value.trim(),
      code: domain.code.trim() || undefined,
    });
    domain.result = data;
  } catch (error) {
    useAlert(error.response?.data?.error || error.message);
  } finally {
    domain.isChecking = false;
  }
};

// `matches` là null khi người dùng không nhập mã — lúc đó chỉ trả lời được
// "có bản ghi xác minh Zalo hay không", chứ không nói được là đúng mã.
const domainMessage = computed(() => {
  const result = domain.result;
  if (!result) return '';
  let key = 'MISSING';
  if (result.found && result.matches === true) key = 'MATCHES';
  else if (result.found && result.matches === false) key = 'MISMATCH';
  else if (result.found) key = 'FOUND';
  return t(`INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.${key}`, {
    domain: result.domain,
  });
});

const finish = () => {
  stopPolling();
  router.replace({
    name: 'settings_inboxes_add_agents',
    params: { page: 'new', inbox_id: inbox.value.id },
  });
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.DESC')"
    />

    <form
      v-if="!isConfigured"
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createConnection"
    >
      <h3 class="text-sm font-medium text-n-slate-12 mb-2">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.STEPS.CREDENTIALS') }}
      </h3>

      <label :class="{ error: v$.name.$error }">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHANNEL_NAME.LABEL') }}
        <input
          v-model="form.name"
          type="text"
          :placeholder="
            $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHANNEL_NAME.PLACEHOLDER')
          "
          @blur="v$.name.$touch"
        />
        <span v-if="v$.name.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHANNEL_NAME.ERROR') }}
        </span>
      </label>

      <label :class="{ error: v$.appId.$error }">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_ID.LABEL') }}
        <input
          v-model="form.appId"
          type="text"
          inputmode="numeric"
          :placeholder="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_ID.PLACEHOLDER')"
          @blur="v$.appId.$touch"
        />
        <span v-if="v$.appId.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_ID.ERROR') }}
        </span>
      </label>
      <p class="help-text">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_ID.SUBTITLE') }}
      </p>

      <label :class="{ error: v$.appSecret.$error }">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_SECRET.LABEL') }}
        <input
          v-model="form.appSecret"
          type="password"
          autocomplete="off"
          :placeholder="
            $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_SECRET.PLACEHOLDER')
          "
          @blur="v$.appSecret.$touch"
        />
        <span v-if="v$.appSecret.$error" class="message">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_SECRET.ERROR') }}
        </span>
      </label>
      <p class="help-text">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.APP_SECRET.SUBTITLE') }}
      </p>

      <label>
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.OA_ID.LABEL') }}
        <input
          v-model="form.oaId"
          type="text"
          inputmode="numeric"
          :placeholder="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.OA_ID.PLACEHOLDER')"
        />
      </label>
      <p class="help-text">
        {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.OA_ID.SUBTITLE') }}
      </p>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>

    <div v-else class="flex flex-col gap-6">
      <section>
        <h3 class="text-sm font-medium text-n-slate-12 mb-2">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.STEPS.PASTE') }}
        </h3>
        <div
          v-for="field in [
            {
              key: 'webhook',
              label: $t('INBOX_MGMT.ADD.ZALO_CHANNEL.FIELDS.WEBHOOK_URL'),
              value: connection.webhook_url,
            },
            {
              key: 'callback',
              label: $t('INBOX_MGMT.ADD.ZALO_CHANNEL.FIELDS.CALLBACK_URL'),
              value: connection.oauth_callback_url,
            },
            {
              key: 'permission',
              label: $t('INBOX_MGMT.ADD.ZALO_CHANNEL.FIELDS.PERMISSION_URL'),
              value: connection.oauth_url,
            },
          ]"
          :key="field.key"
          class="flex items-center gap-2 mb-2"
        >
          <span class="text-sm text-n-slate-11 w-56 shrink-0">{{
            field.label
          }}</span>
          <code
            class="flex-1 truncate text-xs bg-n-alpha-2 rounded px-2 py-1"
            >{{ field.value }}</code
          >
          <NextButton
            faded
            slate
            type="button"
            :label="
              copiedField === field.key
                ? $t('INBOX_MGMT.ADD.ZALO_CHANNEL.FIELDS.COPIED')
                : $t('INBOX_MGMT.ADD.ZALO_CHANNEL.FIELDS.COPY')
            "
            @click="copy(field.key, field.value)"
          />
        </div>
      </section>

      <section>
        <h3 class="text-sm font-medium text-n-slate-12 mb-2">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.STEPS.EVENTS') }}
        </h3>
        <ul class="flex flex-wrap gap-2 m-0 p-0 list-none">
          <li
            v-for="event in requiredEvents"
            :key="event"
            class="text-xs bg-n-alpha-2 rounded px-2 py-1"
          >
            {{ event }}
          </li>
        </ul>
      </section>

      <section>
        <h3 class="text-sm font-medium text-n-slate-12 mb-2">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.STEPS.DOMAIN') }}
        </h3>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.HELP') }}
        </p>
        <div class="flex flex-wrap items-end gap-2">
          <label class="mb-0">
            {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.DOMAIN_LABEL') }}
            <input
              v-model="domain.value"
              type="text"
              :placeholder="
                $t(
                  'INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.DOMAIN_PLACEHOLDER'
                )
              "
            />
          </label>
          <label class="mb-0">
            {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.CODE_LABEL') }}
            <input
              v-model="domain.code"
              type="text"
              :placeholder="
                $t('INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.CODE_PLACEHOLDER')
              "
            />
          </label>
          <NextButton
            faded
            slate
            type="button"
            class="mb-4"
            :is-loading="domain.isChecking"
            :disabled="!domain.value"
            :label="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.DOMAIN_CHECK.BUTTON')"
            @click="checkDomain"
          />
        </div>
        <p v-if="domainMessage" class="text-sm text-n-slate-12">
          {{ domainMessage }}
        </p>
      </section>

      <section>
        <h3 class="text-sm font-medium text-n-slate-12 mb-2">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.STEPS.AUTHORIZE') }}
        </h3>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.AUTHORIZE.HELP') }}
        </p>
        <a
          :href="connection.oauth_url"
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center rounded-md bg-n-blue-9 px-3 py-2 text-sm font-medium text-white"
        >
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.AUTHORIZE.BUTTON') }}
        </a>
      </section>

      <section>
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-sm font-medium text-n-slate-12 m-0">
            {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.STEPS.CHECK') }}
          </h3>
          <NextButton
            faded
            slate
            type="button"
            :is-loading="isChecking"
            :label="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHECKS.REFRESH')"
            @click="refreshStatus()"
          />
        </div>
        <ul class="m-0 p-0 list-none flex flex-col gap-1">
          <li
            v-for="check in checks"
            :key="check.key"
            class="flex items-center justify-between gap-2 bg-n-solid-2 rounded-md outline outline-1 outline-n-container px-3 py-2"
          >
            <span class="text-sm text-n-slate-12">
              {{ $t(`INBOX_MGMT.ADD.ZALO_CHANNEL.CHECKS.${check.key}`) }}
            </span>
            <span
              class="rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap"
              :class="
                check.ok
                  ? 'bg-n-teal-3 text-n-teal-11'
                  : 'bg-n-alpha-2 text-n-slate-11'
              "
            >
              {{
                check.ok
                  ? $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHECKS.DONE')
                  : $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHECKS.PENDING')
              }}
            </span>
          </li>
        </ul>
        <p class="help-text mt-2">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHECKS.HINT') }}
        </p>
      </section>

      <div>
        <NextButton
          solid
          blue
          type="button"
          :disabled="!inbox"
          :label="$t('INBOX_MGMT.ADD.ZALO_CHANNEL.FINISH_BUTTON')"
          @click="finish"
        />
        <span v-if="isLive" class="ml-2 text-sm text-n-teal-11">
          {{ $t('INBOX_MGMT.ADD.ZALO_CHANNEL.CHECKS.DONE') }}
        </span>
      </div>
    </div>
  </div>
</template>
