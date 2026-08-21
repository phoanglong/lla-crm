/* global axios */
import ApiClient from './ApiClient';

class ZaloConnectionsAPI extends ApiClient {
  constructor() {
    super('zalo/connections', { accountScoped: true });
  }

  create(connection) {
    return axios.post(this.url, { connection });
  }

  status(id) {
    return axios.get(`${this.url}/${id}`);
  }

  // Bản ghi TXT là bước duy nhất trong quy trình Zalo nằm ở nhà cung cấp DNS chứ
  // không nằm trong phần mềm, nên cũng là bước duy nhất phải hỏi ra ngoài mới biết.
  checkDomain({ domain, code }) {
    return axios.get(`${this.url}/domain_check`, { params: { domain, code } });
  }
}

export default new ZaloConnectionsAPI();
