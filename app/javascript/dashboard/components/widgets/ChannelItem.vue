<script setup>
import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import ChannelSelector from '../ChannelSelector.vue';

const props = defineProps({
  channel: {
    type: Object,
    required: true,
  },
  enabledFeatures: {
    type: Object,
    required: true,
  },
});

const emit = defineEmits(['channelItemClick']);

const accountId = useMapGetter('getCurrentAccountId');
const getAccount = useMapGetter('accounts/getAccount');

// Một tenant đã khai ứng dụng nền tảng của chính mình thì kênh đó dùng được, kể cả khi bản
// cài đặt không có ứng dụng nào — đó chính là điều "tự mang ứng dụng" có nghĩa.
const tenantApp = platform =>
  Boolean(
    getAccount.value?.(accountId.value)?.platform_apps?.[platform]?.app_id
  );

const hasFbConfigured = computed(
  () => Boolean(window.chatwootConfig?.fbAppId) || tenantApp('facebook')
);

const hasInstagramConfigured = computed(
  () => Boolean(window.chatwootConfig?.instagramAppId) || tenantApp('instagram')
);

const hasTiktokConfigured = computed(
  () => Boolean(window.chatwootConfig?.tiktokAppId) || tenantApp('tiktok')
);

const isActive = computed(() => {
  const { key } = props.channel;
  if (Object.keys(props.enabledFeatures).length === 0) {
    return false;
  }
  if (key === 'website') {
    return props.enabledFeatures.channel_website;
  }
  if (key === 'facebook') {
    return props.enabledFeatures.channel_facebook && hasFbConfigured.value;
  }
  if (key === 'email') {
    return props.enabledFeatures.channel_email;
  }

  if (key === 'instagram') {
    return (
      props.enabledFeatures.channel_instagram && hasInstagramConfigured.value
    );
  }

  if (key === 'tiktok') {
    return props.enabledFeatures.channel_tiktok && hasTiktokConfigured.value;
  }

  if (key === 'voice' || key === 'whatsapp_call') {
    return props.enabledFeatures.channel_voice;
  }

  return [
    'website',
    'twilio',
    'api',
    'whatsapp',
    'sms',
    'telegram',
    'zalo',
    'line',
    'instagram',
    'tiktok',
    'voice',
  ].includes(key);
});

const isComingSoon = computed(() => {
  const { key } = props.channel;
  // Show "Coming Soon" only if the channel is marked as coming soon
  // and the corresponding feature flag is not enabled yet.
  return ['voice'].includes(key) && !isActive.value;
});

const isBeta = computed(() => {
  return ['tiktok', 'voice', 'whatsapp_call'].includes(props.channel.key);
});

const hasVoiceBadge = computed(() => {
  return (
    ['voice', 'whatsapp_call'].includes(props.channel.key) &&
    !!props.enabledFeatures.channel_voice
  );
});

const onItemClick = () => {
  if (isActive.value) {
    emit('channelItemClick', props.channel.key);
  }
};
</script>

<template>
  <ChannelSelector
    :title="channel.title"
    :description="channel.description"
    :icon="channel.icon"
    :is-coming-soon="isComingSoon"
    :is-beta="isBeta"
    :has-voice-badge="hasVoiceBadge"
    :disabled="!isActive"
    @click="onItemClick"
  />
</template>
