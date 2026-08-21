<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { copyTextToClipboard } from 'shared/helpers/clipboard';
import PlatformAppsAPI from 'dashboard/api/platformApps';
import NextButton from 'dashboard/components-next/button/Button.vue';

// Khai ứng dụng nền tảng **của chính tenant**. Vì ứng dụng là của họ, họ đăng ký được một
// URL webhook riêng — và đó là thứ làm cho tin của họ không lẫn với tin của tenant khác.
const props = defineProps({
  platform: { type: String, required: true },
  // Bản cài đặt có sẵn ứng dụng của LLA thì tenant được quyền dùng nhờ; không có thì buộc
  // phải khai ứng dụng của mình.
  platformAppAvailable: { type: Boolean, default: false },
});
const emit = defineEmits(['ready']);

const { t } = useI18n();

const app = ref(null);
const isSaving = ref(false);
const isLoading = ref(true);
const copiedField = ref('');
const form = ref({ appId: '', appSecret: '' });

const label = key =>
  t(`INBOX_MGMT.PLATFORM_APP.${key}`, {
    platform: t(`INBOX_MGMT.PLATFORM_APP.NAMES.${props.platform}`),
  });

const isConfigured = computed(() => Boolean(app.value));

// Không tự nhảy qua bước này khi đã khai: URL webhook và verify token chỉ hiện ở đây, và
// tenant còn phải dán chúng sang trang quản trị ứng dụng của mình. Nhảy qua nghĩa là họ
// không còn đường nào để đọc lại hai giá trị ấy.
onMounted(async () => {
  try {
    const { data } = await PlatformAppsAPI.show(props.platform);
    app.value = data;
  } catch {
    // Chưa khai — đó là trạng thái bình thường của lần đầu.
  } finally {
    isLoading.value = false;
  }
});

const save = async () => {
  isSaving.value = true;
  try {
    const { data } = await PlatformAppsAPI.create({
      platform: props.platform,
      app_id: form.value.appId.trim(),
      app_secret: form.value.appSecret.trim(),
    });
    app.value = data;
    form.value.appSecret = '';
  } catch (error) {
    useAlert(
      error.response?.data?.message ||
        error.response?.data?.error ||
        error.message
    );
  } finally {
    isSaving.value = false;
  }
};

const copy = async (field, value) => {
  await copyTextToClipboard(value);
  copiedField.value = field;
};

const useSharedApp = () => emit('ready', null);
</script>

<template>
  <div v-if="!isLoading" class="flex flex-col gap-4">
    <template v-if="!isConfigured">
      <div>
        <h3 class="text-sm font-medium text-n-slate-12 mb-1">
          {{ label('TITLE') }}
        </h3>
        <p class="help-text">{{ label('SUBTITLE') }}</p>
      </div>

      <label>
        {{ label('APP_ID_LABEL') }}
        <input
          v-model="form.appId"
          type="text"
          :placeholder="label('APP_ID_PLACEHOLDER')"
        />
      </label>

      <label>
        {{ label('APP_SECRET_LABEL') }}
        <input
          v-model="form.appSecret"
          type="password"
          autocomplete="off"
          :placeholder="label('APP_SECRET_PLACEHOLDER')"
        />
      </label>

      <div class="flex items-center gap-2">
        <NextButton
          solid
          blue
          type="button"
          :is-loading="isSaving"
          :disabled="!form.appId || !form.appSecret"
          :label="label('SAVE_BUTTON')"
          @click="save"
        />
        <NextButton
          v-if="platformAppAvailable"
          faded
          slate
          type="button"
          :label="label('USE_SHARED_BUTTON')"
          @click="useSharedApp"
        />
      </div>
    </template>

    <template v-else>
      <div>
        <h3 class="text-sm font-medium text-n-slate-12 mb-1">
          {{ label('CONFIGURED_TITLE') }}
        </h3>
        <p class="help-text">{{ label('CONFIGURED_SUBTITLE') }}</p>
      </div>

      <div
        v-for="field in [
          {
            key: 'webhook',
            label: label('WEBHOOK_URL'),
            value: app.webhook_url,
          },
          {
            key: 'verify',
            label: label('VERIFY_TOKEN'),
            value: app.verify_token,
          },
        ]"
        :key="field.key"
        class="flex items-center gap-2"
      >
        <span class="text-sm text-n-slate-11 w-56 shrink-0">{{
          field.label
        }}</span>
        <code class="flex-1 truncate text-xs bg-n-alpha-2 rounded px-2 py-1">{{
          field.value
        }}</code>
        <NextButton
          faded
          slate
          type="button"
          :label="copiedField === field.key ? label('COPIED') : label('COPY')"
          @click="copy(field.key, field.value)"
        />
      </div>

      <div>
        <NextButton
          solid
          blue
          type="button"
          :label="label('CONTINUE_BUTTON')"
          @click="emit('ready', app)"
        />
      </div>
    </template>
  </div>
</template>
