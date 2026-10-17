# Quán Nhậu Dzô

Game mở quán nhậu vỉa hè: bày bàn, nướng mồi, rót bia, giữ khách vui, né công an và dân anh chị. Chơi được trên điện thoại, iPad và máy tính.

Toàn bộ game nằm trong `index.html`, không cần cài đặt hay build.

## Cách chơi

- **Đồ có sẵn** (bia, đá, khô gà, trà đá…): chạm là lên khay.
- **Món nấu**: chạm rổ nguyên liệu (mực, ốc, bò…) rồi chạm bếp. Cùng một nguyên liệu, bếp khác ra món khác: mực + bếp nướng = mực nướng, mực + chảo = mực xào sa tế, mực + nồi lẩu = lẩu hải sản (tốn 2 phần).
- **Nhập hàng** trước mỗi đêm. Nguyên liệu tươi để qua đêm sẽ hư một phần. Hết hàng giữa đêm thì chạm rổ trống để gọi mối giao gấp (đắt hơn 40%).
- **Thuê người làm** theo đêm: Dì Ba phụ bếp (tự bày món chín ra khay), Bé Út chạy bàn (tự bưng đồ có sẵn), Chị Lành thu ngân (tự tính tiền, khách dễ bo).
- Sổ thu chi cuối đêm ghi tiền nhập hàng, lương, món cháy, món hết hàng và hàng còn trong kho.

## Đêm thử thách mỗi ngày và bảng xếp hạng

Mỗi ngày (theo giờ Việt Nam) có một đề chung: cùng mô hình, cùng khu phố, cùng lượt khách và tình huống cho mọi người. Điểm là tiền lãi của đêm đó. Bảng xếp hạng có 4 tab: Hôm nay, Hôm qua, Tuần này (cộng điểm cao nhất mỗi ngày) và Mô hình (kỷ lục 28 ngày của từng mô hình).

Khi chưa cấu hình, thử thách vẫn chơi được nhưng điểm chỉ lưu trên máy người chơi.

### Bật bảng xếp hạng (Supabase, gói miễn phí)

1. Tạo tài khoản và một project tại https://supabase.com. Chọn region Singapore cho gần Việt Nam.
2. Vào **SQL Editor → New query**, dán toàn bộ nội dung `supabase/schema.sql` rồi bấm **Run**.
3. Vào **Project Settings → API Keys**, chép khoá **publishable** (`sb_publishable_…`) hoặc khoá legacy **anon public**. Không bao giờ đưa khoá `sb_secret_…`/`service_role` vào game.
4. Trong `index.html`, tìm dòng `const RANK={url:"",key:""};` và điền vào:
   ```js
   const RANK={url:"https://<project-ref>.supabase.co",key:"sb_publishable_..."};
   ```
   Anon key được phép để công khai: mọi bảng đều bật RLS, và trình duyệt chỉ gọi được các hàm `qnd_*`.

### Chống gian lận

- Máy chủ phát một mã lượt khi người chơi bắt đầu. Mỗi mã chỉ nộp điểm được một lần.
- Lượt kết thúc dưới 80 giây hoặc kéo dài quá 1 giờ bị từ chối.
- Trần điểm 12 triệu một đêm, tối đa 30 lượt mỗi người mỗi ngày, biệt danh tục tĩu bị chặn.
- Lượt bị từ chối vẫn được lưu kèm cờ để chủ game xem lại. Các ngưỡng chỉnh trong hàm `qnd_cfg()`.

Lệnh quản trị hay dùng (chạy trong SQL Editor):

```sql
select * from qnd_runs where flag is not null order by started_at desc;   -- xem lượt bị đánh dấu
update qnd_players set banned = true where nick = 'Tên';                  -- khoá người chơi
```
