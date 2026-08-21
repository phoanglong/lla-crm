/* global axios */
import ApiClient from './ApiClient';

class AiProvidersAPI extends ApiClient {
  constructor() {
    super('ai/providers', { accountScoped: true });
  }

  create(provider) {
    return axios.post(this.url, { provider });
  }

  update(name, provider) {
    return axios.patch(`${this.url}/${name}`, { provider });
  }

  delete(name) {
    return axios.delete(`${this.url}/${name}`);
  }

  // Gọi thật tới nhà cung cấp: cấu hình "trông đúng" không nói được gì.
  verify(name) {
    return axios.post(`${this.url}/${name}/verify`);
  }
}

export default new AiProvidersAPI();
