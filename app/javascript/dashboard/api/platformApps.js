/* global axios */
import ApiClient from './ApiClient';

class PlatformAppsAPI extends ApiClient {
  constructor() {
    super('platform_apps', { accountScoped: true });
  }

  show(platform) {
    return axios.get(`${this.url}/${platform}`);
  }

  create(platformApp) {
    return axios.post(this.url, { platform_app: platformApp });
  }

  update(platform, platformApp) {
    return axios.patch(`${this.url}/${platform}`, {
      platform_app: platformApp,
    });
  }
}

export default new PlatformAppsAPI();
