# LLA CRM

Nền tảng quản lý hội thoại khách hàng đa kênh (omnichannel CRM) của LLA —
inbox hợp nhất cho Telegram, Zalo OA, Website widget, và (đang chuẩn bị)
Facebook Messenger, Instagram, WhatsApp, Shopee, TikTok.

> **Đây là repo SẢN PHẨM chuẩn (canonical) để phát triển.**
> Repo `phoanglong/omn_crm_lla` là repo chương trình: đặc tả (SQL/OpenAPI/AsyncAPI),
> ADR/quyết định, control-plane R&D và tài liệu vận hành. Dev sản phẩm làm ở đây;
> tra cứu spec/quyết định ở repo chương trình. (ADR-OMCRM-027)

## Nguồn gốc và giấy phép

Sản phẩm được phát triển **dựa trên nền tảng [Chatwoot](https://github.com/chatwoot/chatwoot)**
(bản community, giấy phép MIT) — xem `LICENSE` và `NOTICE`. LLA giữ nguyên
ghi công Chatwoot theo yêu cầu MIT; thương hiệu Chatwoot không được dùng làm
nhận diện của LLA CRM. Thư mục `enterprise/` của upstream (giấy phép riêng)
không thuộc phạm vi sử dụng.

Chiến lược upstream: repo giữ khả năng đối chiếu với `chatwoot/chatwoot` để
tiếp nhận bản vá bảo mật và cherry-pick tính năng phù hợp (fetch upstream theo
tag, review từng phần — không merge mù).

## Cấu trúc chính

- Mã nguồn Chatwoot-derived: cấu trúc thư mục gốc (app/, config/, ...).
- `lla/zalo-bridge/` — service Node độc lập nối Zalo OA ↔ inbox API
  (OAuth v4 refresh xoay vòng, webhook secret-path token, egress VN qua proxy).
- Branch `lla-brand` — nhận diện LLA (logo/brand assets) đang chạy production.
- Kế hoạch branch `lla-stable` — build image ổn định từ tag upstream + tuỳ biến
  LLA (Việt hoá sâu, loại dấu vết Chatwoot khỏi UI) — xem completion plan ở repo
  chương trình.

## Vận hành production

Deploy qua Coolify trên VPS LLA; domain `crm.llavn.cloud` (CRM) và
`zbridge.llavn.cloud` (bridge). Runbook chi tiết:
`omn_crm_lla:docs/runbooks/lla-crm-production.md`. Secret không nằm trong repo.

## Đóng góp

Mỗi thay đổi đi theo branch + PR; không commit secret/PII; giữ nguyên
`LICENSE`/`NOTICE`; thay đổi kiến trúc/kênh cần ADR ở repo chương trình.
