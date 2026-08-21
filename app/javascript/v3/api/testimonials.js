import wootAPI from './apiClient';

// The testimonial feed used to be hardcoded to `testimonials.cdn.chatwoot.com`
// and fetched by every visitor who opened the sign-up page. It is an
// installation setting now, empty by default, and empty means no request.
export const getTestimonialContent = () => {
  const url = window.globalConfig?.TESTIMONIALS_URL;
  if (!url) {
    return Promise.resolve({ data: [] });
  }
  return wootAPI.get(url);
};
